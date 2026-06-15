defmodule Zaq.Agent.StreamEvents do
  @moduledoc """
  Reduces Jido AI ask-stream events into ZAQ runtime output.

  This module owns request-local stream concerns: realtime buffered broadcasts,
  per-turn trace capture, tool-call capture, and final usage/result extraction.
  """

  alias Zaq.Agent.RequestRegistry
  alias Zaq.Agent.Status
  alias Zaq.Engine.Messages.Incoming

  @flush_chars 20
  @flush_interval_ms 100
  @terminal_kinds [:request_completed, :request_failed, :request_cancelled]
  @input_token_keys [:input_tokens, :prompt_tokens, :input, :promptTokenCount, :inputTokenCount]
  @output_token_keys [
    :output_tokens,
    :completion_tokens,
    :output,
    :candidatesTokenCount,
    :outputTokenCount
  ]
  @total_token_keys [:total_tokens, :total, :totalTokenCount]
  @token_count_keys @input_token_keys ++ @output_token_keys ++ @total_token_keys

  @type result :: %{
          answer: term(),
          usage: map(),
          trace: [map()],
          tool_calls: [map()],
          termination_reason: term(),
          incoming: Incoming.t()
        }

  @spec consume(Enumerable.t(), Incoming.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def consume(events, %Incoming{} = incoming, opts \\ []) do
    state = initial_state(incoming, opts)

    final_state =
      Enum.reduce_while(events, state, fn event, state ->
        state = handle_event(event, state)

        if terminal_kind?(kind(event)) do
          {:halt, flush(state, force?: true, now: field(event, :at_ms))}
        else
          {:cont, state}
        end
      end)

    final_state = flush(final_state, force?: true)

    case final_state.error do
      nil -> {:ok, result(final_state)}
      error -> {:error, error}
    end
  end

  defp initial_state(%Incoming{} = incoming, opts) do
    started_at = Keyword.get(opts, :started_at, System.monotonic_time(:millisecond))

    %{
      incoming: incoming,
      node_router: Keyword.get(opts, :node_router, Zaq.NodeRouter),
      status_module: Keyword.get(opts, :status_module, Status),
      request_id: request_id(incoming),
      server_id: Keyword.get(opts, :server_id),
      agent: Keyword.get(opts, :agent),
      started_at: started_at,
      last_flush_ms: started_at,
      current_key: nil,
      current_stage: nil,
      current_intent: nil,
      current_full: "",
      current_model: nil,
      current_started_at_ms: nil,
      current_ended_at_ms: nil,
      buffer: "",
      turns: %{},
      trace: [],
      tool_calls: %{},
      answer: nil,
      usage: %{},
      termination_reason: nil,
      error: nil
    }
    |> register(:running)
  end

  defp handle_event(event, state) do
    case kind(event) do
      :llm_delta ->
        handle_llm_delta(event, state)

      :llm_completed ->
        handle_llm_completed(event, state)

      :tool_started ->
        handle_tool_started(event, state)

      :tool_completed ->
        handle_tool_completed(event, state)

      :request_completed ->
        state |> flush_trace_segment(event) |> handle_request_completed(event)

      :request_failed ->
        state |> flush_trace_segment(event) |> handle_request_failed(event)

      :request_cancelled ->
        state
        |> flush_trace_segment(event)
        |> Map.put(:termination_reason, :cancelled)
        |> register(:cancelled)

      _ ->
        state
    end
  end

  defp handle_llm_delta(event, state) do
    data = data(event)
    delta = data_get(data, :delta)
    chunk_type = normalize_chunk_type(data_get(data, :chunk_type))

    if is_binary(delta) and delta != "" and chunk_type in [:content, :thinking] do
      event_key = {field(event, :iteration), field(event, :llm_call_id), chunk_type}
      {stage, intent} = display_target(chunk_type)

      state =
        if state.current_key != nil and state.current_key != event_key do
          state
          |> flush(force?: true)
          |> flush_trace_segment(event)
        else
          state
        end

      full = if state.current_key == event_key, do: state.current_full <> delta, else: delta

      started_at_ms =
        if state.current_key == event_key,
          do: state.current_started_at_ms,
          else: field(event, :at_ms)

      model = data_get(data, :model) || state.current_model

      state = %{
        state
        | current_key: event_key,
          current_stage: stage,
          current_intent: intent,
          current_full: full,
          current_model: model,
          current_started_at_ms: started_at_ms,
          current_ended_at_ms: field(event, :at_ms),
          buffer: state.buffer <> delta,
          turns: put_turn_delta(state.turns, event, chunk_type, delta)
      }

      maybe_flush(state, event)
      |> register(:streaming)
    else
      state
    end
  end

  defp handle_llm_completed(event, state) do
    usage = normalize_usage(data_get(data(event), :usage))

    if map_size(usage) > 0 do
      %{state | usage: merge_usage(state.usage, usage)}
    else
      state
    end
  end

  defp handle_tool_started(event, state) do
    data = data(event)

    tool_call_id =
      field(event, :tool_call_id) || data_get(data, :tool_call_id) || field(event, :id)

    tool_call = %{
      "id" => tool_call_id,
      "type" => "tool_call",
      "turn_id" => to_string(field(event, :iteration) || 0),
      "content" => field(event, :tool_name) || data_get(data, :tool_name) || "tool",
      "name" => field(event, :tool_name) || data_get(data, :tool_name),
      "arguments" => json_safe(data_get(data, :arguments)),
      "started_at" => timestamp(event),
      "started_at_ms" => field(event, :at_ms),
      "status" => "started"
    }

    state = %{state | tool_calls: Map.put(state.tool_calls, tool_call_id, tool_call)}
    broadcast_tool(state, tool_call, :started) |> register(:tool_running)
  end

  defp handle_tool_completed(event, state) do
    data = data(event)

    tool_call_id =
      field(event, :tool_call_id) || data_get(data, :tool_call_id) || field(event, :id)

    tool_call =
      state.tool_calls
      |> Map.get(tool_call_id, %{"id" => tool_call_id})
      |> Map.merge(%{
        "type" => "tool_call",
        "turn_id" => to_string(field(event, :iteration) || 0),
        "content" => field(event, :tool_name) || data_get(data, :tool_name) || "tool",
        "name" => field(event, :tool_name) || data_get(data, :tool_name),
        "response" => json_safe(data_get(data, :result)),
        "duration_ms" => data_get(data, :duration_ms),
        "ended_at" => timestamp(event),
        "ended_at_ms" => field(event, :at_ms),
        "status" => "completed"
      })
      |> reject_nil_values()
      |> json_safe()

    state = %{
      state
      | tool_calls: Map.put(state.tool_calls, tool_call_id, tool_call),
        trace: [tool_call | state.trace]
    }

    broadcast_tool(state, tool_call, :completed) |> register(:tool_completed)
  end

  defp handle_request_completed(state, event) do
    data = data(event)
    usage = completed_request_usage(state.usage, data_get(data, :usage))

    %{
      state
      | answer: data_get(data, :result),
        usage: usage,
        termination_reason: data_get(data, :termination_reason) || :complete
    }
    |> register(:completed)
  end

  defp handle_request_failed(state, event) do
    data = data(event)

    %{state | error: data_get(data, :error) || data_get(data, :reason) || :request_failed}
    |> register(:failed)
  end

  defp maybe_flush(state, event) do
    now = field(event, :at_ms) || System.monotonic_time(:millisecond)

    if byte_size(state.buffer) > @flush_chars and now - state.last_flush_ms >= @flush_interval_ms do
      flush(state, force?: true, now: now)
    else
      state
    end
  end

  defp flush(%{buffer: ""} = state, _opts), do: state

  defp flush(state, opts) do
    now = Keyword.get(opts, :now) || System.monotonic_time(:millisecond)

    incoming =
      state.status_module.broadcast(
        state.incoming,
        state.current_stage,
        state.current_full,
        state.node_router,
        update_intent: state.current_intent
      )

    %{state | incoming: incoming, buffer: "", last_flush_ms: now}
    |> register(:streaming)
  end

  defp broadcast_tool(state, tool_call, status) do
    name = Map.get(tool_call, "name") || "tool"
    message = if status == :completed, do: "Finished #{name}", else: "Using #{name}"

    incoming =
      state.status_module.broadcast(state.incoming, :tool_call, message, state.node_router,
        update_intent: :tool_call
      )

    %{state | incoming: incoming}
  end

  defp result(state) do
    %{
      answer: state.answer || state.current_full,
      usage: state.usage,
      trace: Enum.reverse(state.trace),
      tool_calls: state.tool_calls |> Map.values(),
      termination_reason: state.termination_reason,
      measurements: measurements(state),
      model: model(state),
      agent: sanitize_agent(state.agent),
      incoming: state.incoming
    }
  end

  defp flush_trace_segment(%{current_key: nil} = state, _event), do: state
  defp flush_trace_segment(%{current_full: ""} = state, _event), do: state

  defp flush_trace_segment(state, event) do
    {iteration, llm_call_id, chunk_type} = state.current_key
    trace_type = trace_chunk_key(chunk_type)

    entry =
      %{
        "id" => llm_call_id || "llm:#{iteration || 0}:#{trace_type}",
        "type" => trace_type,
        "turn_id" => to_string(iteration || 0),
        "llm_call_id" => llm_call_id,
        "model" => state.current_model,
        "started_at" => timestamp(state.current_started_at_ms),
        "started_at_ms" => state.current_started_at_ms,
        "ended_at" => timestamp(state.current_ended_at_ms || field(event, :at_ms)),
        "ended_at_ms" => state.current_ended_at_ms || field(event, :at_ms),
        "duration_ms" =>
          duration_ms(
            state.current_started_at_ms,
            state.current_ended_at_ms || field(event, :at_ms)
          )
      }
      |> maybe_put_trace_content(trace_type, state.current_full)
      |> reject_nil_values()
      |> json_safe()

    %{state | trace: [entry | state.trace]}
  end

  defp register(%{request_id: request_id} = state, status) do
    RequestRegistry.put(request_id, %{
      status: status,
      server_id: state.server_id,
      agent: sanitize_agent(state.agent),
      current_stage: state.current_stage,
      current_intent: state.current_intent,
      current_content: state.current_full,
      buffered_chars: byte_size(state.buffer || ""),
      tool_calls: state.tool_calls |> Map.values(),
      termination_reason: state.termination_reason,
      updated_at_ms: System.system_time(:millisecond)
    })

    state
  end

  defp request_id(%Incoming{metadata: metadata, message_id: message_id}) when is_map(metadata) do
    Map.get(metadata, :request_id) || Map.get(metadata, "request_id") || message_id
  end

  defp request_id(%Incoming{message_id: message_id}), do: message_id

  defp sanitize_agent(%{id: id, name: name}), do: %{id: id, name: name}
  defp sanitize_agent(_), do: nil

  defp measurements(state) do
    %{
      "latency_ms" => duration_ms(state.started_at, System.monotonic_time(:millisecond)),
      "total_tokens" => usage_value(state.usage, [:total_tokens]),
      "input_tokens" => usage_value(state.usage, [:input_tokens, :prompt_tokens]),
      "output_tokens" => usage_value(state.usage, [:output_tokens, :completion_tokens]),
      "turn_count" =>
        state.turns |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length(),
      "llm_call_count" =>
        state.turns
        |> Map.keys()
        |> Enum.map(&elem(&1, 1))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> length(),
      "tool_call_count" => map_size(state.tool_calls)
    }
    |> reject_nil_values()
    |> json_safe()
  end

  defp model(state) do
    state.trace
    |> Enum.find_value(&Map.get(&1, "model"))
  end

  defp usage_value(usage, keys) when is_map(usage) do
    Enum.find_value(keys, fn key ->
      case Map.get(usage, key) || Map.get(usage, to_string(key)) do
        value when is_integer(value) -> value
        value -> token_value(value)
      end
    end)
  end

  defp usage_value(_usage, _keys), do: nil

  defp token_counts(usage) when is_map(usage) do
    sources = usage_sources(usage)

    input_tokens = first_token_value(sources, @input_token_keys)
    output_tokens = first_token_value(sources, @output_token_keys)
    total_tokens = first_token_value(sources, @total_token_keys)

    %{}
    |> maybe_put_token_count(:input_tokens, input_tokens)
    |> maybe_put_token_count(:output_tokens, output_tokens)
    |> maybe_put_token_count(
      :total_tokens,
      total_tokens || token_sum(input_tokens, output_tokens)
    )
  end

  defp usage_sources(usage) do
    nested_tokens = Map.get(usage, :tokens) || Map.get(usage, "tokens")

    [usage, nested_tokens]
    |> Enum.filter(&is_map/1)
  end

  defp first_token_value(sources, keys) do
    Enum.find_value(sources, fn usage ->
      Enum.find_value(keys, fn key ->
        usage
        |> token_key_value(key)
        |> token_value()
      end)
    end)
  end

  defp token_key_value(usage, key) when is_atom(key),
    do: Map.get(usage, key) || Map.get(usage, to_string(key))

  defp token_key_value(usage, key), do: Map.get(usage, key)

  defp token_value(value) do
    case numeric_value(value) do
      {:ok, number} when is_number(number) -> max(trunc(number), 0)
      :error -> nil
    end
  end

  defp maybe_put_token_count(usage, _key, nil), do: usage
  defp maybe_put_token_count(usage, key, value), do: Map.put(usage, key, value)

  defp token_sum(input_tokens, output_tokens)
       when is_integer(input_tokens) and is_integer(output_tokens),
       do: input_tokens + output_tokens

  defp token_sum(_input_tokens, _output_tokens), do: nil

  defp numeric_value(value) when is_integer(value), do: {:ok, value}
  defp numeric_value(value) when is_float(value), do: {:ok, value}

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp numeric_value(_), do: :error

  defp duration_ms(start_ms, end_ms) when is_integer(start_ms) and is_integer(end_ms),
    do: max(end_ms - start_ms, 0)

  defp duration_ms(_start_ms, _end_ms), do: nil

  defp timestamp(%{at_ms: at_ms}), do: timestamp(at_ms)
  defp timestamp(%{"at_ms" => at_ms}), do: timestamp(at_ms)
  defp timestamp(%_{} = event), do: timestamp(Map.get(event, :at_ms))

  defp timestamp(event) when is_map(event),
    do: timestamp(Map.get(event, :at_ms) || Map.get(event, "at_ms"))

  defp timestamp(at_ms) when is_integer(at_ms) do
    at_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  rescue
    _ -> nil
  end

  defp timestamp(_), do: nil

  @doc "Returns a value safe to store in JSON/map database fields."
  def json_safe(value) do
    safe = do_json_safe(value)

    case Jason.encode(safe) do
      {:ok, _encoded} -> safe
      {:error, _reason} -> inspect(value)
    end
  end

  defp put_turn_delta(turns, event, chunk_type, delta) do
    turn_id = to_string(field(event, :iteration) || 0)
    key = {turn_id, field(event, :llm_call_id)}

    trace_key = trace_chunk_key(chunk_type)

    Map.update(turns, key, new_turn(event, turn_id, trace_key, delta), fn turn ->
      Map.update!(turn, trace_key, &(&1 <> delta))
    end)
  end

  defp new_turn(event, turn_id, trace_key, delta) do
    %{
      "iteration" => field(event, :iteration) || 0,
      "turn_id" => turn_id,
      "llm_call_id" => field(event, :llm_call_id),
      "reasoning" => "",
      "content" => ""
    }
    |> Map.put(trace_key, delta)
  end

  defp trace_chunk_key(:thinking), do: "reasoning"
  defp trace_chunk_key(:content), do: "content"

  defp maybe_put_trace_content(entry, "content", _content), do: entry

  defp maybe_put_trace_content(entry, _trace_type, content),
    do: Map.put(entry, "content", content)

  defp display_target(:thinking), do: {:thinking, :reasoning}
  defp display_target(:content), do: {:answering, :stream_delta}

  defp terminal_kind?(kind), do: kind in @terminal_kinds

  defp normalize_chunk_type(value) when value in [:content, :thinking], do: value
  defp normalize_chunk_type("content"), do: :content
  defp normalize_chunk_type("thinking"), do: :thinking
  defp normalize_chunk_type(_), do: :unknown

  defp normalize_usage(usage) when is_map(usage),
    do: normalize_usage_map(usage, derive_token_counts?: true)

  defp normalize_usage(_), do: %{}

  defp normalize_usage_map(usage, opts) do
    normalized =
      Map.new(usage, fn {key, value} ->
        key = normalize_usage_key(key)
        {key, normalize_usage_value(key, value)}
      end)

    if Keyword.get(opts, :derive_token_counts?, false) do
      Map.merge(normalized, token_counts(normalized))
    else
      normalized
    end
  end

  defp merge_usage(existing, incoming) do
    Map.merge(normalize_usage(existing), normalize_usage(incoming), &merge_usage_value/3)
  end

  defp completed_request_usage(existing, incoming) do
    incoming = normalize_usage(incoming)

    if map_size(incoming) > 0 do
      incoming
    else
      normalize_usage(existing)
    end
  end

  defp numeric_usage_value(value) do
    case numeric_value(value) do
      {:ok, number} -> number
      :error -> value
    end
  end

  defp normalize_usage_key("input_tokens"), do: :input_tokens
  defp normalize_usage_key("output_tokens"), do: :output_tokens
  defp normalize_usage_key("total_tokens"), do: :total_tokens
  defp normalize_usage_key("prompt_tokens"), do: :prompt_tokens
  defp normalize_usage_key("completion_tokens"), do: :completion_tokens
  defp normalize_usage_key("promptTokenCount"), do: :promptTokenCount
  defp normalize_usage_key("inputTokenCount"), do: :inputTokenCount
  defp normalize_usage_key("candidatesTokenCount"), do: :candidatesTokenCount
  defp normalize_usage_key("outputTokenCount"), do: :outputTokenCount
  defp normalize_usage_key("totalTokenCount"), do: :totalTokenCount
  defp normalize_usage_key(key), do: key

  defp normalize_usage_value(key, value)
       when key in @token_count_keys,
       do: numeric_usage_value(value)

  defp normalize_usage_value(_key, value) when is_map(value),
    do: normalize_usage_map(value, derive_token_counts?: false)

  defp normalize_usage_value(_key, value), do: value

  defp merge_usage_value(_key, left, right) when is_map(left) and is_map(right),
    do: merge_usage(left, right)

  defp merge_usage_value(key, left, right)
       when key in @token_count_keys do
    case {numeric_value(left), numeric_value(right)} do
      {{:ok, left}, {:ok, right}} -> left + right
      _ -> right
    end
  end

  defp merge_usage_value(_key, _left, right), do: right

  defp kind(event), do: field(event, :kind)
  defp data(event), do: field(event, :data) || %{}

  defp field(%module{} = struct, key) when is_atom(module), do: Map.get(struct, key)
  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_, _), do: nil

  defp data_get(data, key), do: field(data, key)

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp do_json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp do_json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp do_json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp do_json_safe(%Time{} = value), do: Time.to_iso8601(value)

  defp do_json_safe(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {safe_key(key), json_safe(value)} end)
    |> Map.put("__struct__", Atom.to_string(struct.__struct__))
  end

  defp do_json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {safe_key(key), json_safe(value)} end)
  end

  defp do_json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> do_json_safe()
  defp do_json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp do_json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp do_json_safe(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value), do: value

  defp do_json_safe(value) when is_float(value), do: value

  defp do_json_safe(value)
       when is_pid(value) or is_reference(value) or is_port(value) or is_function(value),
       do: inspect(value)

  defp do_json_safe(value), do: inspect(value)

  defp safe_key(key) when is_binary(key), do: key
  defp safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp safe_key(key), do: inspect(key)
end
