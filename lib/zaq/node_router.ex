defmodule Zaq.NodeRouter do
  @moduledoc """
  Cross-role event router for single-node and multi-node deployments.

  Responsibilities:

  - Resolve the target node for a role from the role -> supervisor mapping.
  - Dispatch `%Zaq.Event{}` hops to role boundary APIs (`Zaq.<Role>.Api`).
  - Support both sync and async hop execution.
  - Support multi-hop event chains by recursively dispatching returned
    `next_hop` values.
  - Provide a legacy `call/4` compatibility wrapper by wrapping calls as
    `:invoke` events.

  This module does not own service business logic; each role API handles its
  own actions.

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
    bo: Zaq.Bo.Api
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
    {:ok, dispatch_ctx} = prepare_dispatch(event, role, runtime)
    do_dispatch(dispatch_ctx)
  end

  def dispatch(%Event{} = event, _runtime) do
    %{event | response: {:error, {:invalid_event, :missing_or_invalid_next_hop}}}
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

  defp async_start(runtime, fun) when is_function(fun, 0) do
    runtime
    |> Map.get(:async_start_fn, &Task.Supervisor.start_child(Zaq.TaskSupervisor, &1))
    |> then(& &1.(fun))
  end

  defp action_for(%Event{opts: opts}) when is_list(opts) do
    case Keyword.get(opts, :action, :invoke) do
      action when is_atom(action) -> action
      _ -> :invoke
    end
  end

  defp action_for(_event), do: :invoke

  defp prepare_dispatch(%Event{} = event, role, runtime) when is_map(runtime) and is_atom(role) do
    {event, hop_type} = consume_current_hop(event)
    supervisor = Map.fetch!(@supervisor_map, role)
    current = current_node(runtime)

    {:ok,
     %{
       event: event,
       action: action_for(event),
       hop_type: hop_type,
       api_module: Map.fetch!(@role_api_map, role),
       current: current,
       target: find_node(supervisor, runtime) || current,
       runtime: runtime
     }}
  end

  defp do_dispatch(%{hop_type: :sync} = dispatch_ctx) do
    dispatch_ctx
    |> do_dispatch_sync()
    |> continue_dispatch(dispatch_ctx.runtime)
  end

  defp do_dispatch(%{hop_type: :async} = dispatch_ctx) do
    _ =
      async_start(dispatch_ctx.runtime, fn ->
        _ = do_dispatch_sync(dispatch_ctx) |> continue_dispatch(dispatch_ctx.runtime)
        :ok
      end)

    dispatch_ctx.event
  end

  defp do_dispatch_sync(%{
         event: event,
         api_module: api_module,
         action: action,
         current: current,
         target: target,
         runtime: runtime
       }) do
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

  defp continue_dispatch(%Event{next_hop: %EventHop{}} = event, runtime),
    do: dispatch(event, runtime)

  defp continue_dispatch(%Event{} = event, _runtime), do: event

  defp unwrap_call_response(%Event{response: {:error, {:rpc_failed, _, _}} = error}), do: error
  defp unwrap_call_response(%Event{response: response}), do: response

  defp consume_current_hop(%Event{next_hop: %EventHop{} = next_hop, hops: hops} = event)
       when is_list(hops) do
    {%{event | next_hop: nil, hops: hops ++ [next_hop]}, next_hop.type}
  end

  defp consume_current_hop(%Event{} = event), do: {%{event | next_hop: nil}, :sync}
end

defmodule Zaq.NodeRouter.Behaviour do
  @moduledoc """
  Behaviour for NodeRouter implementations.

  Used for testing and alternative routing strategies.
  """
  @callback find_node(supervisor :: atom()) :: node() | nil
end
