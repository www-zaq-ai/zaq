defmodule Zaq.Channels.Bridge do
  @moduledoc """
  Behaviour and shared helpers for channel bridge modules.

  All bridges must expose a canonical inbound mapper (`to_internal/2`) and
  outbound sender (`send_reply/2`). Runtime/lifecycle callbacks vary by bridge
  type and are optional.
  """

  alias Zaq.{Agent, Event, NodeRouter}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Utils.ParseUtils

  @callback to_internal(map(), map()) :: Incoming.t() | {:error, term()}
  @callback send_reply(term(), map()) :: :ok | {:error, term()}

  @callback start_runtime(map()) :: :ok | {:error, term()}
  @callback stop_runtime(map()) :: :ok | {:error, term()}
  @callback send_typing(map() | atom() | String.t(), String.t(), map()) :: :ok | {:error, term()}

  @callback add_reaction(
              map() | atom() | String.t(),
              String.t(),
              String.t(),
              String.t(),
              map()
            ) :: :ok | {:error, term()}

  @callback remove_reaction(
              map() | atom() | String.t(),
              String.t(),
              String.t(),
              String.t(),
              map()
            ) :: :ok | {:error, term()}

  @callback subscribe_thread_reply(map(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback unsubscribe_thread_reply(map(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback open_dm_channel(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback fetch_profile(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback test_connection(map(), String.t()) :: {:ok, term()} | {:error, term()}
  @callback list_mailboxes(map(), map()) :: {:ok, [String.t()]} | {:error, term()}
  @callback resolve_agent_selection(map(), Incoming.t(), keyword()) :: map() | nil
  @callback before_incoming(map(), map(), keyword(), module()) ::
              {:ok, {map(), map(), keyword()}} | {:error, term()}
  @callback after_incoming(map(), map(), keyword(), term(), module()) :: term()

  @optional_callbacks start_runtime: 1,
                      stop_runtime: 1,
                      before_incoming: 4,
                      after_incoming: 5,
                      send_typing: 3,
                      add_reaction: 5,
                      remove_reaction: 5,
                      subscribe_thread_reply: 3,
                      unsubscribe_thread_reply: 3,
                      open_dm_channel: 2,
                      fetch_profile: 2,
                      test_connection: 2,
                      list_mailboxes: 2,
                      resolve_agent_selection: 3

  @doc "Routes inbound payloads through optional hooks and bridge handler."
  @spec route_incoming(module(), map(), map(), keyword()) :: term()
  def route_incoming(bridge_module, config, payload, sink_opts)
      when is_atom(bridge_module) and is_map(config) and is_map(payload) and is_list(sink_opts) do
    with {:ok, {hook_config, hook_payload, hook_sink_opts}} <-
           before_incoming(config, payload, sink_opts, bridge_module),
         true <-
           function_exported?(bridge_module, :handle_from_listener, 3) || {:error, :unsupported},
         result <- bridge_module.handle_from_listener(hook_config, hook_payload, hook_sink_opts) do
      after_incoming(hook_config, hook_payload, hook_sink_opts, result, bridge_module)
    else
      {:error, _reason} = error -> error
      false -> {:error, :unsupported}
      other -> other
    end
  end

  @doc "Default before-incoming hook pass-through."
  @spec before_incoming(map(), map(), keyword(), module()) ::
          {:ok, {map(), map(), keyword()}} | {:error, term()}
  def before_incoming(config, payload, sink_opts, bridge_module)
      when is_map(config) and is_map(payload) and is_list(sink_opts) and is_atom(bridge_module) do
    if function_exported?(bridge_module, :before_incoming, 4) do
      bridge_module.before_incoming(config, payload, sink_opts, __MODULE__)
    else
      {:ok, {config, payload, sink_opts}}
    end
  end

  @doc "Default after-incoming hook pass-through."
  @spec after_incoming(map(), map(), keyword(), term(), module()) :: term()
  def after_incoming(config, payload, sink_opts, result, bridge_module)
      when is_map(config) and is_map(payload) and is_list(sink_opts) and is_atom(bridge_module) do
    if function_exported?(bridge_module, :after_incoming, 5) do
      bridge_module.after_incoming(config, payload, sink_opts, result, __MODULE__)
    else
      result
    end
  end

  @doc "Normalizes event/bridge ack responses to `:ok` or `{:error, reason}`."
  @spec ack_from_event_response(term()) :: :ok | {:error, term()}
  def ack_from_event_response(response)

  def ack_from_event_response(:ok), do: :ok
  def ack_from_event_response({:ok, _ack}), do: :ok
  def ack_from_event_response({:error, _reason} = error), do: error
  def ack_from_event_response(%{ack: ack}), do: ack_from_event_response(ack)
  def ack_from_event_response(%{"ack" => ack}), do: ack_from_event_response(ack)
  def ack_from_event_response(%Event{response: response}), do: ack_from_event_response(response)
  def ack_from_event_response(other), do: {:error, {:invalid_ack, other}}

  @doc """
  Persists a processed incoming message and its metadata through the engine.

  If `conversations_module` is the default `Zaq.Engine.Conversations`, routing
  goes through `NodeRouter.dispatch/1` and the event envelope. Otherwise the
  override module is called directly for testability.
  """
  @spec persist_from_incoming(Incoming.t(), map(), module(), term(), module()) :: term()
  def persist_from_incoming(
        %Incoming{} = incoming,
        metadata,
        conversations_module,
        actor,
        node_router_module \\ NodeRouter
      )
      when is_map(metadata) and is_atom(conversations_module) and is_atom(node_router_module) do
    if conversations_module == Conversations do
      event =
        Event.new(
          %{incoming: incoming, metadata: metadata},
          :engine,
          actor: actor,
          opts: [action: :persist_from_incoming]
        )

      node_router_module.dispatch(event).response
    else
      conversations_module.persist_from_incoming(incoming, metadata)
    end
  end

  @doc "Runs pipeline through NodeRouter and normalizes response shape."
  @spec run_pipeline_with_node_router(Incoming.t(), keyword(), map() | nil, map(), module()) ::
          Outgoing.t() | {:error, term()}
  def run_pipeline_with_node_router(
        %Incoming{} = msg,
        pipeline_opts,
        agent_selection,
        actor,
        node_router_module
      )
      when is_list(pipeline_opts) and is_map(actor) and is_atom(node_router_module) do
    event =
      Event.new(
        msg,
        :agent,
        actor: actor,
        opts: [action: :run_pipeline, pipeline_opts: pipeline_opts]
      )
      |> put_agent_selection_assign(agent_selection)

    case node_router_module.dispatch(event).response do
      %Outgoing{} = outgoing -> outgoing
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_pipeline_response, other}}
    end
  end

  @doc "Adds validated agent selection into event assigns."
  @spec put_agent_selection_assign(Event.t(), map() | nil) :: Event.t()
  def put_agent_selection_assign(%Event{} = event, nil), do: event

  def put_agent_selection_assign(%Event{} = event, %{"agent_id" => _} = selection) do
    %{event | assigns: Map.put(event.assigns || %{}, "agent_selection", selection)}
  end

  def put_agent_selection_assign(%Event{} = event, _selection), do: event

  @doc """
  Returns first conversation-eligible candidate agent selection from ordered candidates.

  ## Parameters
  - `candidates`: List of `{source_atom, agent_id}` tuples in priority order.
    Sources: `:channel_assignment`, `:provider_default`, `:global_default`
  - `agent_module`: Module implementing conversation eligibility lookup
    (default: `Zaq.Agent`)

  ## Examples

      iex> candidates = [
      ...>   {:channel_assignment, 42},
      ...>   {:provider_default, 10},
      ...>   {:global_default, 1}
      ...> ]
      iex> first_active_selection(candidates)
      %{"agent_id" => 42, "source" => "channel_assignment"}
  """
  @spec first_active_selection([{atom(), term()}], module()) :: map() | nil
  def first_active_selection(candidates, agent_module \\ Agent)

  def first_active_selection(candidates, agent_module)
      when is_list(candidates) and is_atom(agent_module) do
    Enum.find_value(candidates, fn {source, candidate_id} ->
      with {:ok, id} <- ParseUtils.parse_int_strict(candidate_id),
           {:ok, _agent} <- agent_module.get_conversation_enabled_agent(id) do
        %{"agent_id" => id, "source" => Atom.to_string(source)}
      else
        _ -> nil
      end
    end)
  end
end
