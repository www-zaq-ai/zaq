defmodule Zaq.Agent.ContextWindow.RequestTransformer do
  @moduledoc """
  Per-turn Jido.AI request transformer that enforces the configured model context window.

  This module projects the outgoing provider request without mutating the Jido
  agent's retained state. Older historical messages may be removed from the
  request, but the system prompt, current turn, active ReAct/tool interaction,
  tools, and output schema remain mandatory.
  """

  @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

  alias Jido.AI.Reasoning.ReAct.Config
  alias Zaq.Agent.ContextWindow.RequestEstimator

  @default_safety_margin 0.05

  @impl true
  def transform_request(request, _state, %Config{} = config, runtime_context) do
    window = Map.get(runtime_context || %{}, :context_window, %{})

    with {:ok, budget} <- input_budget(window, config),
         {:ok, messages} <- fit_messages(request, config, window, budget) do
      {:ok, %{messages: messages}}
    end
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

  defp fit_messages(%{messages: messages} = request, %Config{} = config, window, budget)
       when is_list(messages) do
    request = request_for_estimate(request, config)

    if RequestEstimator.estimate(request, window) <= budget do
      {:ok, messages}
    else
      {mandatory, evictable_units} = split_messages(messages)
      fit_units(request, mandatory, evictable_units, window, budget)
    end
  end

  defp fit_messages(_request, _config, _window, _budget),
    do: {:error, {:context_window_exceeded, :invalid_messages}}

  defp fit_units(request, mandatory, [], window, budget) do
    messages = List.flatten(mandatory)

    if RequestEstimator.estimate(%{request | messages: messages}, window) <= budget do
      {:ok, messages}
    else
      {:error, {:context_window_exceeded, :mandatory_payload_too_large}}
    end
  end

  defp fit_units(request, mandatory, [_drop | remaining], window, budget) do
    messages = List.flatten(remaining ++ mandatory)

    if RequestEstimator.estimate(%{request | messages: messages}, window) <= budget do
      {:ok, messages}
    else
      fit_units(request, mandatory, remaining, window, budget)
    end
  end

  defp split_messages(messages) do
    latest_user_index = latest_user_index(messages) || max(length(messages) - 1, 0)

    {evictable, mandatory} = Enum.split(messages, latest_user_index)

    mandatory =
      evictable
      |> Enum.filter(&(message_role(&1) == "system"))
      |> Kernel.++(mandatory)

    evictable = Enum.reject(evictable, &(message_role(&1) == "system"))

    {Enum.map(mandatory, &[&1]), logical_units(evictable)}
  end

  defp logical_units(messages), do: do_logical_units(messages, []) |> Enum.reverse()

  defp do_logical_units([], units), do: units

  defp do_logical_units([message | rest], units) do
    if message_role(message) == "assistant" and has_tool_calls?(message) do
      {tool_messages, rest} = Enum.split_while(rest, &(message_role(&1) == "tool"))
      do_logical_units(rest, [[message | tool_messages] | units])
    else
      do_logical_units(rest, [[message] | units])
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
