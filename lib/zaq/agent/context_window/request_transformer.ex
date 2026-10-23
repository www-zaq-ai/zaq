defmodule Zaq.Agent.ContextWindow.RequestTransformer do
  @moduledoc """
  Per-turn Jido.AI request transformer that enforces the configured model context window.

  This module projects the outgoing provider request without mutating the Jido
  agent's retained state. Older historical messages may be removed from the
  request, but the system prompt, current turn, active ReAct/tool interaction,
  tools, and output schema remain mandatory. A per-request root reference fences
  the entire execution, including later steering messages, rather than just the
  latest user turn. Eviction preserves the original order of every retained message,
  including system messages interleaved with history.
  """

  @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

  alias Jido.AI.Context, as: AIContext
  alias Jido.AI.Reasoning.ReAct.Config
  alias Zaq.Agent.ContextWindow.RequestEstimator
  alias Zaq.Agent.HistoryLoader
  alias Zaq.Agent.ServerManager
  alias Zaq.Event

  @default_safety_margin 0.05

  @impl true
  def transform_request(request, state, %Config{} = config, runtime_context) do
    window = Map.get(runtime_context || %{}, :context_window, %{})

    with {:ok, request, context} <- refresh_history(request, state, runtime_context || %{}),
         {:ok, budget} <- input_budget(window, config),
         {:ok, messages} <-
           fit_messages(
             request,
             config,
             window,
             budget,
             active_start(context, runtime_context || %{})
           ) do
      {:ok, %{messages: messages}}
    end
  end

  defp refresh_history(
         request,
         state,
         %{execution_history: %{binding: binding, cursors: cursors, scope: scope} = history} =
           runtime_context
       ) do
    event =
      Event.new(Map.put(binding, :after_cursors, cursors), :engine,
        actor: runtime_context[:actor],
        opts: [action: :execution_history, confidential: true, trusted_access_denial: true]
      )

    router = Map.get(runtime_context, :node_router, Zaq.NodeRouter)

    case router.dispatch(event) do
      %{response: {:ok, %{kind: :canonical} = projection}} ->
        with {:ok, projection} <-
               ServerManager.history_projection(history, runtime_context[:actor], projection) do
          project_request(request, state.context, projection, scope)
        end

      %{response: {:error, {:history_access_denied, denial}}} ->
        :ok = ServerManager.retire_history_scope(denial)

        with {:ok, projection} <-
               ServerManager.history_projection(history, runtime_context[:actor]) do
          project_request(request, state.context, projection, scope)
        end

      %{response: {:error, reason}} ->
        {:error, reason}

      _ ->
        {:error, :history_unavailable}
    end
  end

  defp refresh_history(request, state, _runtime_context),
    do: {:ok, request, if(is_map(state), do: Map.get(state, :context))}

  defp project_request(request, context, projection, scope) do
    context =
      HistoryLoader.merge_projection(context, projection.messages, opaque_alias_scope: scope)

    {:ok, %{request | messages: AIContext.to_messages(context)}, context}
  end

  defp input_budget(window, %Config{} = config) do
    max_context_tokens = positive_int(Map.get(window, :max_context_tokens))
    reserved_output_tokens = positive_int(get_in(config.llm, [:max_tokens])) || 0

    with tokens when is_integer(tokens) <- max_context_tokens,
         raw_budget when raw_budget > 0 <- tokens - reserved_output_tokens do
      margin = safety_margin(window)
      {:ok, max(1, floor(raw_budget * (1.0 - margin)))}
    else
      _ -> {:error, {:context_window_exceeded, :no_input_budget}}
    end
  end

  defp fit_messages(
         %{messages: messages} = request,
         %Config{} = config,
         window,
         budget,
         active_start
       )
       when is_list(messages) do
    request = request_for_estimate(request, config)

    if RequestEstimator.estimate(request, window) <= budget do
      {:ok, messages}
    else
      indexed = Enum.with_index(messages)
      evictable_units = eviction_units(indexed, active_start)
      fit_units(request, indexed, evictable_units, window, budget)
    end
  end

  defp fit_messages(_request, _config, _window, _budget, _active_start),
    do: {:error, {:context_window_exceeded, :invalid_messages}}

  defp fit_units(request, indexed, [], window, budget) do
    messages = Enum.map(indexed, &elem(&1, 0))

    if RequestEstimator.estimate(%{request | messages: messages}, window) <= budget do
      {:ok, messages}
    else
      {:error, {:context_window_exceeded, :mandatory_payload_too_large}}
    end
  end

  defp fit_units(request, indexed, [drop | remaining], window, budget) do
    dropped_indices = MapSet.new(drop, &elem(&1, 1))
    indexed = Enum.reject(indexed, &MapSet.member?(dropped_indices, elem(&1, 1)))
    messages = Enum.map(indexed, &elem(&1, 0))

    if RequestEstimator.estimate(%{request | messages: messages}, window) <= budget do
      {:ok, messages}
    else
      fit_units(request, indexed, remaining, window, budget)
    end
  end

  defp eviction_units(indexed, active_start) do
    messages = Enum.map(indexed, &elem(&1, 0))

    latest_user_index =
      active_start || latest_user_index(messages) || max(length(messages) - 1, 0)

    indexed
    |> Enum.reject(fn {message, _index} -> message_role(message) == "system" end)
    |> logical_units()
    |> Enum.reject(fn unit ->
      Enum.any?(unit, fn {_message, index} -> index >= latest_user_index end)
    end)
  end

  defp active_start(%AIContext{} = context, %{execution_root: root}) when is_binary(root) do
    index = Enum.find_index(Enum.reverse(context.entries), &(&1.refs[:execution_root] == root))

    if is_integer(index),
      do: index + if(is_binary(context.system_prompt), do: 1, else: 0),
      else: 0
  end

  defp active_start(_context, _runtime_context), do: nil

  defp logical_units(messages), do: do_logical_units(messages, []) |> Enum.reverse()

  defp do_logical_units([], units), do: units

  defp do_logical_units([{message, _index} = indexed | rest], units) do
    if message_role(message) == "assistant" and has_tool_calls?(message) do
      {tool_messages, rest} = Enum.split_while(rest, &(message_role(elem(&1, 0)) == "tool"))
      do_logical_units(rest, [[indexed | tool_messages] | units])
    else
      do_logical_units(rest, [[indexed] | units])
    end
  end

  defp latest_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {message, index} ->
      if message_role(message) == "user", do: index
    end)
  end

  defp message_role(message), do: message_value(message, :role) |> to_string()

  defp has_tool_calls?(message) do
    case message_value(message, :tool_calls) || message_value(message, :tool_call) do
      nil -> false
      [] -> false
      _ -> true
    end
  end

  defp message_value(%_{} = struct, key), do: struct |> Map.from_struct() |> message_value(key)
  defp message_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp message_value(_message, _key), do: nil

  defp request_for_estimate(request, %Config{} = config) do
    if is_nil(config.output) do
      request
    else
      Map.put(request, :output, config.output)
    end
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  defp safety_margin(window) do
    case Map.get(window, :safety_margin, @default_safety_margin) do
      value when is_number(value) and value >= 0 and value < 1 -> value
      _ -> @default_safety_margin
    end
  end
end
