defmodule Zaq.Agent.RequestEffects do
  @moduledoc """
  Serializes private, request-local Action effects in the owning Jido agent.

  Configured tools opt in by implementing this behaviour. Each Action owns its
  initial value and pure reducer; this module owns request isolation, invocation
  replay protection, cancellation and private completion transport. Reducers run
  against current state in native tool declaration order, never worker snapshots.

  Commands use a reserved StateOp envelope which is consumed before Jido captures
  traces. Opted-in tools' arguments/results and checkpoint tokens are redacted.
  On success, final values keyed by Action module are sent to the existing stream
  sink before the terminal event. No extra process, registry or store is created.
  """

  alias Jido.Agent.StateOp.SetPath
  alias Jido.Agent.Strategy.State, as: StrategyState
  alias Jido.AI.Request

  @callback init_request_effect() :: term()
  @callback reduce_request_effect(term(), term()) :: {:ok, term()} | {:error, atom()}

  @doc "Builds isolated state for the opted-in tools of one request."
  def new(request_id, incarnation, tools) do
    handlers = tools |> Enum.filter(&handler?/1) |> Map.new(&{&1.name(), &1})

    %{
      request_id: request_id,
      incarnation: incarnation,
      status: :active,
      handlers: handlers,
      values: initial_values(handlers),
      seen: MapSet.new(),
      last_seq: -1
    }
  end

  @doc "Initializes enabled requests; busy starts retain their active state."
  def start(agent, request_id, tools) do
    if StrategyState.get(agent, %{})[:status] in [:awaiting_llm, :awaiting_tool] do
      agent
    else
      effects = new(request_id, self(), tools)

      state =
        if effects.handlers == %{},
          do: Map.delete(agent.state, :request_effects),
          else: Map.put(agent.state, :request_effects, effects)

      %{agent | state: state}
    end
  end

  @doc "Creates a private command only for an enabled handler in the active request."
  def command(
        %{
          request_id: id,
          state: %{
            request_effects: %{request_id: id, incarnation: pid, status: :active, values: values}
          }
        },
        handler,
        payload
      )
      when is_binary(id) and is_pid(pid) and is_map_key(values, handler) do
    {:ok,
     %SetPath{
       path: [:request_effect],
       value: %{request_id: id, incarnation: pid, handler: handler, payload: payload}
     }}
  end

  def command(_context, _handler, _payload), do: {:error, :inactive_request_effect}

  @doc "Binds the native invocation ID; model parameters cannot select a handler."
  def bind_invocation(%{action_module: handler, id: id}, {:ok, value, effects}) do
    effects =
      Enum.map(effects, fn
        %SetPath{path: [:request_effect], value: %{handler: ^handler} = command} = effect ->
          %{effect | value: Map.put(command, :invocation_id, id)}

        effect ->
          effect
      end)

    {:ok, value, effects}
  end

  def bind_invocation(_call, result), do: result

  @doc "Applies an enabled Action's command once against its current value."
  def apply_command(
        %{status: :active, request_id: id, incarnation: pid} = effects,
        %{
          request_id: id,
          incarnation: pid,
          invocation_id: call,
          handler: handler,
          payload: payload
        }
      )
      when is_binary(call) and is_map_key(effects.values, handler) do
    if MapSet.member?(effects.seen, call) do
      {:ok, effects}
    else
      with {:ok, value} <- handler.reduce_request_effect(effects.values[handler], payload) do
        {:ok,
         %{
           effects
           | values: Map.put(effects.values, handler, value),
             seen: MapSet.put(effects.seen, call)
         }}
      end
    end
  end

  def apply_command(_effects, _command), do: {:error, :stale_request_effect}

  @doc "Freezes successful values or discards all values on failure/cancellation."
  def finish(effects, :completed), do: %{effects | status: :completed}

  def finish(effects, :failed),
    do: %{effects | status: :failed, values: initial_values(effects.handlers), seen: MapSet.new()}

  @doc "Discards values when native cancellation or failure settles the request."
  def settle(agent) do
    effects = agent.state[:request_effects]
    request = effects && get_in(agent.state, [:requests, effects.request_id])

    if effects && request && request.status in [:failed, :error, :cancelled],
      do: %{agent | state: Map.put(agent.state, :request_effects, finish(effects, :failed))},
      else: agent
  end

  @doc "Consumes private effects and redacts them before native trace projection."
  def accept_event(agent, event) do
    case agent.state[:request_effects] do
      nil ->
        {:ok, agent, event}

      %{status: :active, request_id: id, incarnation: pid, last_seq: seq} = effects
      when event.request_id == id and pid == self() and event.seq > seq ->
        {effects, event} = apply_event(%{effects | last_seq: event.seq}, event)
        agent = %{agent | state: Map.put(agent.state, :request_effects, effects)}
        send_snapshot(agent, effects)
        {:ok, agent, redact_event(event, effects.handlers)}

      %{status: :failed, request_id: id, incarnation: pid} = effects
      when event.request_id == id and pid == self() and
             event.kind in [:request_completed, :request_failed, :request_cancelled] ->
        {:ok, agent, redact_event(event, effects.handlers)}

      _ ->
        :stale
    end
  end

  defp apply_event(effects, %{kind: :tool_completed, tool_name: name, data: data} = event) do
    with {:ok, handler} <- Map.fetch(effects.handlers, name),
         {:ok, _, [%SetPath{path: [:request_effect], value: command}]} <- data[:result],
         true <- command[:handler] == handler do
      case apply_command(effects, command) do
        {:ok, effects} ->
          {effects, event}

        {:error, reason} ->
          {effects, %{event | data: Map.put(data, :result, {:error, reason, []})}}
      end
    else
      false ->
        {effects, %{event | data: Map.put(data, :result, {:error, :invalid_effect_handler, []})}}

      _ ->
        {effects, event}
    end
  end

  defp apply_event(effects, %{kind: :request_completed} = event),
    do: {finish(effects, :completed), event}

  defp apply_event(effects, %{kind: kind} = event)
       when kind in [:request_failed, :request_cancelled], do: {finish(effects, :failed), event}

  defp apply_event(effects, event), do: {effects, event}

  defp send_snapshot(agent, %{status: :completed} = effects) do
    case Request.stream_sink(agent, effects.request_id) do
      {:pid, pid} ->
        send(pid, {__MODULE__, effects.request_id, effects.incarnation, effects.values})

      nil ->
        :ok
    end
  end

  defp send_snapshot(_agent, _effects), do: :ok

  @doc "Consumes only the snapshot sent by this request's runtime before completion."
  def take_snapshot(request_id, runtime_pid) when is_binary(request_id) and is_pid(runtime_pid) do
    receive do
      {__MODULE__, ^request_id, ^runtime_pid, values} -> values
    after
      0 -> %{}
    end
  end

  def take_snapshot(_request_id, _runtime_pid), do: %{}

  defp redact_event(%{kind: :checkpoint} = event, _handlers),
    do: %{event | data: Map.delete(event.data, :token)}

  defp redact_event(%{kind: :llm_completed, data: data} = event, handlers) do
    calls =
      Enum.map(data[:tool_calls] || [], fn call ->
        if Map.has_key?(handlers, call.name), do: Map.put(call, :arguments, %{}), else: call
      end)

    %{event | data: Map.put(data, :tool_calls, calls)}
  end

  defp redact_event(%{tool_name: name, data: data} = event, handlers)
       when is_map_key(handlers, name) do
    data = Map.put(data, :arguments, %{})

    data =
      case data[:result] do
        {:ok, _, _} -> Map.put(data, :result, {:ok, %{effect_applied: true}, []})
        {:error, _, _} -> Map.put(data, :result, {:error, :effect_rejected, []})
        _ -> data
      end

    %{event | data: data}
  end

  defp redact_event(event, _handlers), do: event

  defp initial_values(handlers),
    do: Map.new(handlers, fn {_name, module} -> {module, module.init_request_effect()} end)

  defp handler?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :init_request_effect, 0) and
      function_exported?(module, :reduce_request_effect, 2)
  end
end
