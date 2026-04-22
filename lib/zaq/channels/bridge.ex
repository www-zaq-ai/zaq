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

  @optional_callbacks start_runtime: 1,
                      stop_runtime: 1,
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

  @doc "Returns first active candidate agent selection from ordered candidates."
  @spec first_active_selection([{atom(), term()}], module()) :: map() | nil
  def first_active_selection(candidates, agent_module \\ Agent)

  def first_active_selection(candidates, agent_module)
      when is_list(candidates) and is_atom(agent_module) do
    Enum.find_value(candidates, fn {source, candidate_id} ->
      with {:ok, id} <- ParseUtils.parse_int_strict(candidate_id),
           {:ok, _agent} <- agent_module.get_active_agent(id) do
        %{"agent_id" => id, "source" => Atom.to_string(source)}
      else
        _ -> nil
      end
    end)
  end
end
