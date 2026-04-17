defmodule Zaq.NodeRouter do
  @moduledoc """
  Routes service calls to the correct node based on which supervisor
  is running where.

  When services are split across nodes (e.g. agent on ai@localhost,
  bo on bo@localhost), direct local calls won't work. This module
  checks all connected nodes and dispatches via :rpc.call/4 to the
  node where the supervisor is actually running.

  Falls back to a local call if no peer node has the supervisor,
  which handles the single-node (all roles) case transparently.

  ## Event-first example

      event = Zaq.Event.new(%{module: String, function: :upcase, args: ["hello"]}, :bo)
      routed_event = NodeRouter.dispatch(event)
      routed_event.response

  ## Legacy example (deprecated)

      # Calls Zaq.Agent.Retrieval.ask/2 on whichever node runs Zaq.Agent.Supervisor
      NodeRouter.call(:agent, Zaq.Agent.Retrieval, :ask, [question, opts])
  """

  @behaviour Zaq.NodeRouter.Behaviour

  alias Zaq.{Event, EventHop}

  @supervisor_map %{
    agent: Zaq.Agent.Supervisor,
    ingestion: Zaq.Ingestion.Supervisor,
    channels: Zaq.Channels.Supervisor,
    engine: Zaq.Engine.Supervisor,
    bo: ZaqWeb.Endpoint
  }

  @role_api_map %{
    agent: Zaq.Agent.Api,
    ingestion: Zaq.Ingestion.Api,
    channels: Zaq.Channels.Api,
    engine: Zaq.Engine.Api,
    bo: Zaq.Channels.Api
  }

  @doc """
  Returns the supervisor map. Used by ServiceUnavailable component
  and other modules that need to check role → supervisor mapping.
  """
  def supervisor_map, do: @supervisor_map

  @doc """
  Dispatches an event to the node that owns `event.next_hop.destination`.

  Always returns a `%Zaq.Event{}` for both sync and async hop types.
  """
  @spec dispatch(Event.t()) :: Event.t()
  def dispatch(%Event{} = event), do: dispatch(event, %{})

  @spec dispatch(Event.t(), map()) :: Event.t()
  def dispatch(%Event{next_hop: %EventHop{destination: role}} = event, runtime)
      when is_map(runtime) do
    supervisor = Map.fetch!(@supervisor_map, role)
    api_module = Map.fetch!(@role_api_map, role)
    action = action_for(event)
    current = current_node(runtime)
    target = find_node(supervisor, runtime) || current

    if target == current do
      api_module.handle_event(event, action, nil)
    else
      case rpc_call(runtime, target, api_module, :handle_event, [event, action, nil]) do
        {:badrpc, reason} ->
          %{event | response: {:error, {:rpc_failed, target, reason}}}

        %Event{} = routed_event ->
          routed_event

        other ->
          %{event | response: {:error, {:invalid_event_response, target, other}}}
      end
    end
  end

  @doc """
  Calls mod.fun(args) on the node running the given service role.
  Falls back to a local call if the service runs locally or no peer has it.

  Deprecated: use `dispatch/1` with `%Zaq.Event{}`.
  """
  def call(role, mod, fun, args) do
    call(role, mod, fun, args, %{})
  end

  def call(role, mod, fun, args, runtime) when is_map(runtime) do
    _ = Map.fetch!(@supervisor_map, role)

    event =
      Event.new(
        %{module: mod, function: fun, args: args},
        role,
        opts: [action: :invoke]
      )

    dispatch(event, runtime)
    |> unwrap_call_response()
  end

  @doc """
  Returns the node where the given supervisor is running.
  Checks local node first, then all connected peers.
  Returns nil if not found anywhere.
  """
  def find_node(supervisor) do
    find_node(supervisor, %{})
  end

  @doc """
  Returns the node where the given supervisor is running, consulting the
  provided runtime map for node/peer overrides. Used in tests and internally.
  """
  def find_node(supervisor, runtime) when is_map(runtime) do
    current = current_node(runtime)
    all_nodes = [current | node_list(runtime)]
    Enum.find(all_nodes, current, &supervisor_running?(&1, supervisor, runtime))
  end

  defp supervisor_running?(n, supervisor, runtime) do
    if n == current_node(runtime) do
      whereis(runtime, supervisor) != nil
    else
      case rpc_call(runtime, n, Process, :whereis, [supervisor]) do
        {:badrpc, _} -> false
        nil -> false
        _pid -> true
      end
    end
  end

  defp current_node(runtime) do
    runtime
    |> Map.get(:current_node_fn, &node/0)
    |> then(& &1.())
  end

  defp node_list(runtime) do
    runtime
    |> Map.get(:node_list_fn, &Node.list/0)
    |> then(& &1.())
  end

  defp whereis(runtime, supervisor) do
    runtime
    |> Map.get(:whereis_fn, &Process.whereis/1)
    |> then(& &1.(supervisor))
  end

  defp rpc_call(runtime, n, mod, fun, args) do
    runtime
    |> Map.get(:rpc_call_fn, &:rpc.call/4)
    |> then(& &1.(n, mod, fun, args))
  end

  defp action_for(%Event{opts: opts}) when is_list(opts) do
    case Keyword.get(opts, :action, :invoke) do
      action when is_atom(action) -> action
      _ -> :invoke
    end
  end

  defp action_for(_event), do: :invoke

  defp unwrap_call_response(%Event{response: {:error, {:rpc_failed, _, _}} = error}), do: error
  defp unwrap_call_response(%Event{response: response}), do: response
end

defmodule Zaq.NodeRouter.Behaviour do
  @moduledoc false
  @callback find_node(supervisor :: atom()) :: node() | nil
end
