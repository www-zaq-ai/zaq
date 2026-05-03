defmodule Zaq.Agent.JidoTelemetryBridge do
  @moduledoc """
  Single bridge for Jido AI telemetry events.

  Handles two responsibilities from one telemetry handler:
  - logs level-aware observability events,
  - broadcasts BO status updates for key LLM/tool lifecycle events.
  """

  use GenServer

  require Logger

  alias Jido.AI.Observe
  alias Zaq.Agent.{Factory, Status}
  alias Zaq.Engine.Telemetry

  @handler_id "zaq-agent-jido-telemetry-bridge"
  @tool_trace_table :zaq_tool_trace_events
  @tool_trace_lock_table :zaq_tool_trace_locks

  @request_events for event <- [:start, :complete, :failed, :rejected, :cancelled],
                      do: [:jido, :ai, :request, event]

  @llm_events for event <- [:span, :start, :delta, :complete, :error],
                  do: [:jido, :ai, :llm, event]

  @tool_events for event <- [:span, :start, :retry, :complete, :error, :timeout],
                   do: [:jido, :ai, :tool, event]

  @tool_execute_events for event <- [:start, :stop, :exception],
                           do: [:jido, :ai, :tool, :execute, event]

  @default_config %{
    enabled: true,
    include_llm_deltas: false,
    max_payload_chars: 2000
  }

  # @default_mcp_prefixes ["mcp__", "mcp_"]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    cfg = config()

    enabled? =
      if cfg.enabled do
        case :telemetry.attach_many(
               @handler_id,
               events(cfg.include_llm_deltas),
               &__MODULE__.handle_event/4,
               cfg
             ) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning(
              "Jido telemetry bridge disabled: telemetry attach failed: #{inspect(reason)}"
            )

            false
        end
      else
        false
      end

    {:ok, %{enabled?: enabled?}}
  end

  @impl true
  def terminate(_reason, %{enabled?: true}) do
    :telemetry.detach(@handler_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @doc false
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, cfg) do
    cfg = normalize_callback_config(cfg)
    remember_request_context_from_metadata(metadata)
    track_tool_event(event, measurements, metadata)
    maybe_publish_tool_traces(event, metadata)
    maybe_record_business_metrics(event, measurements, metadata)
    maybe_broadcast_status(event, measurements, metadata, cfg)

    if skip_event?(event, cfg) do
      :ok
    else
      summary = summarize_event(event, measurements, metadata)

      case severity(event) do
        :error -> Logger.error(summary)
        :warning -> Logger.warning(summary)
        :info -> Logger.info(summary)
      end

      Logger.debug(fn ->
        details =
          %{measurements: measurements, metadata: metadata}
          |> Observe.sanitize_sensitive()
          |> truncate_term(cfg.max_payload_chars)

        "#{summary} details=#{inspect(details, pretty: true, limit: :infinity)}"
      end)

      :ok
    end
  end

  defp skip_event?([:jido, :ai, :llm, :delta], %{include_llm_deltas: false}), do: true
  defp skip_event?(_, _), do: false

  defp config do
    app_config =
      case Application.get_env(:zaq, :jido_telemetry_bridge, %{}) do
        value when is_map(value) -> value
        value when is_list(value) -> Map.new(value)
        _ -> %{}
      end

    @default_config
    |> Map.merge(app_config)
    |> normalize_callback_config()
  end

  defp normalize_callback_config(cfg) when is_map(cfg) do
    %{
      enabled: Map.get(cfg, :enabled, true),
      include_llm_deltas: Map.get(cfg, :include_llm_deltas, false),
      max_payload_chars: max(64, Map.get(cfg, :max_payload_chars, 2000))
    }
  end

  defp normalize_callback_config(_), do: @default_config

  defp track_tool_event(event, measurements, metadata)
       when event in [[:jido, :ai, :tool, :start], [:jido, :ai, :tool, :execute, :start]] do
    with request_id when is_binary(request_id) and request_id != "" <- request_id(metadata),
         tool_call_id when is_binary(tool_call_id) and tool_call_id != "" <-
           tool_call_id(metadata),
         tool_name when is_binary(tool_name) and tool_name != "" <- tool_name(metadata) do
      merge_trace(request_id, tool_call_id, tool_name, fn current ->
        current
        |> merge_tool_event_fields(metadata, measurements)
      end)

      remember_request_context(request_id)
    else
      _ -> :ok
    end
  end

  defp track_tool_event(event, measurements, metadata)
       when event in [
              [:jido, :ai, :tool, :complete],
              [:jido, :ai, :tool, :execute, :stop],
              [:jido, :ai, :tool, :error],
              [:jido, :ai, :tool, :timeout],
              [:jido, :ai, :tool, :execute, :exception]
            ] do
    with request_id when is_binary(request_id) and request_id != "" <- request_id(metadata),
         tool_call_id when is_binary(tool_call_id) and tool_call_id != "" <-
           tool_call_id(metadata),
         tool_name when is_binary(tool_name) and tool_name != "" <- tool_name(metadata) do
      status = if success_event?(event), do: "ok", else: "error"

      merge_trace(request_id, tool_call_id, tool_name, fn current ->
        current
        |> merge_tool_event_fields(metadata, measurements)
        |> Map.put(:status, status)
      end)

      remember_request_context(request_id)
    else
      _ -> :ok
    end
  end

  defp track_tool_event(_event, _measurements, _metadata), do: :ok

  defp maybe_publish_tool_traces(event, metadata)
       when event in [
              [:jido, :ai, :request, :complete],
              [:jido, :ai, :request, :failed],
              [:jido, :ai, :request, :cancelled],
              [:jido, :ai, :request, :rejected]
            ] do
    case request_id(metadata) do
      request_id when is_binary(request_id) and request_id != "" ->
        traces = list_request_traces(request_id)

        proc_ctx = Process.get(:zaq_status_context)
        ctx_request_id = proc_ctx_value(proc_ctx, :request_id)

        case {get_request_context(request_id), ctx_request_id} do
          {%{collector_pid: collector_pid}, ctx_req_id}
          when is_pid(collector_pid) and is_binary(ctx_req_id) and ctx_req_id != "" ->
            send(collector_pid, {:zaq_tool_traces, ctx_req_id, traces})

          _ ->
            :ok
        end

        clear_request_traces(request_id)

      _ ->
        :ok
    end
  end

  defp maybe_publish_tool_traces(_event, _metadata), do: :ok

  defp maybe_record_business_metrics([:jido, :ai, :llm, :start], _measurements, metadata) do
    Telemetry.record("qa.llm.call.count", 1, telemetry_dimensions(metadata))
  end

  defp maybe_record_business_metrics([:jido, :ai, :request, :complete], measurements, metadata) do
    dims = telemetry_dimensions(metadata)

    maybe_record_token_metric("qa.tokens.prompt", Map.get(measurements, :input_tokens), dims)
    maybe_record_token_metric("qa.tokens.completion", Map.get(measurements, :output_tokens), dims)
    maybe_record_token_metric("qa.tokens.total", Map.get(measurements, :total_tokens), dims)

    :ok
  end

  defp maybe_record_business_metrics(_event, _measurements, _metadata), do: :ok

  defp maybe_record_token_metric(_metric_key, value, _dims) when not is_integer(value), do: :ok

  defp maybe_record_token_metric(metric_key, value, dims),
    do: Telemetry.record(metric_key, value, dims)

  defp remember_request_context_from_metadata(metadata) do
    case request_id(metadata) do
      request_id when is_binary(request_id) and request_id != "" ->
        remember_request_context(request_id)

      _ ->
        :ok
    end
  end

  defp telemetry_dimensions(metadata) do
    request_id = request_id(metadata)

    case request_id && get_request_context(request_id) do
      %{telemetry_dimensions: dims} when is_map(dims) -> dims
      _ -> %{}
    end
  end

  defp events(include_llm_deltas) do
    llm_events =
      if include_llm_deltas,
        do: @llm_events,
        else: Enum.reject(@llm_events, &match?([:jido, :ai, :llm, :delta], &1))

    @request_events ++ llm_events ++ @tool_events ++ @tool_execute_events
  end

  defp summarize_event(event, measurements, metadata) do
    event_name = event_name(event)
    attrs = summary_attrs(measurements, metadata)

    case attrs do
      "" -> "[JidoAI] #{event_name}"
      _ -> "[JidoAI] #{event_name} #{attrs}"
    end
  end

  defp event_name([:jido, :ai, scope, kind]), do: "#{scope}.#{kind}"
  defp event_name([:jido, :ai, :tool, :execute, kind]), do: "tool.execute.#{kind}"
  defp event_name(other), do: Enum.map_join(other, ".", &to_string/1)

  defp summary_attrs(measurements, metadata) do
    [
      {:request_id, Map.get(metadata, :request_id)},
      {:run_id, Map.get(metadata, :run_id)},
      {:llm_call_id, Map.get(metadata, :llm_call_id)},
      {:tool_call_id, Map.get(metadata, :tool_call_id)},
      {:tool_name, Map.get(metadata, :tool_name)},
      {:model, Map.get(metadata, :model)},
      {:operation, Map.get(metadata, :operation)},
      {:strategy, Map.get(metadata, :strategy)},
      {:duration_ms, Map.get(measurements, :duration_ms)},
      {:input_tokens, Map.get(measurements, :input_tokens)},
      {:output_tokens, Map.get(measurements, :output_tokens)},
      {:total_tokens, Map.get(measurements, :total_tokens)},
      {:retry_count, Map.get(measurements, :retry_count)},
      {:queue_ms, Map.get(measurements, :queue_ms)},
      {:termination_reason, Map.get(metadata, :termination_reason)},
      {:error_type, Map.get(metadata, :error_type)}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{stringify(v)}" end)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp severity([:jido, :ai, :request, :failed]), do: :error
  defp severity([:jido, :ai, :llm, :error]), do: :error
  defp severity([:jido, :ai, :tool, :error]), do: :error
  defp severity([:jido, :ai, :tool, :execute, :exception]), do: :error
  defp severity([:jido, :ai, :tool, :timeout]), do: :warning
  defp severity(_), do: :info

  defp truncate_term(value, max_chars) when is_binary(value) do
    if String.length(value) > max_chars do
      kept = String.slice(value, 0, max_chars)
      hidden = String.length(value) - max_chars
      "#{kept}...(truncated #{hidden} chars)"
    else
      value
    end
  end

  defp truncate_term(value, max_chars) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, truncate_term(v, max_chars)} end)
  end

  defp truncate_term(value, max_chars) when is_list(value) do
    Enum.map(value, &truncate_term(&1, max_chars))
  end

  defp truncate_term(value, _max_chars), do: value

  defp maybe_broadcast_status([:jido, :ai, :llm, :start], _measurements, metadata, _cfg) do
    case resolve_ctx(metadata) do
      nil -> :ok
      ctx -> Status.broadcast(ctx, :answering, "Thinking…", ctx.node_router)
    end

    :ok
  end

  defp maybe_broadcast_status([:jido, :ai, :llm, :delta], measurements, metadata, cfg) do
    if cfg.include_llm_deltas do
      case {resolve_ctx(metadata), reasoning_delta_text(measurements, metadata)} do
        {nil, _} -> :ok
        {_, nil} -> :ok
        {ctx, text} -> Status.broadcast(ctx, :retrieving, text, ctx.node_router)
      end
    end

    :ok
  end

  defp maybe_broadcast_status(event, _measurements, metadata, _cfg)
       when event in [[:jido, :ai, :tool, :start], [:jido, :ai, :tool, :execute, :start]] do
    case resolve_ctx(metadata) do
      nil ->
        :ok

      ctx ->
        tool_name = Map.get(metadata, :tool_name) || "unknown"
        # stage = tool_stage(tool_name)
        Status.broadcast(ctx, :retrieving, "Calling #{tool_name}…", ctx.node_router)
    end

    :ok
  end

  defp maybe_broadcast_status(_event, _measurements, _metadata, _cfg), do: :ok

  defp reasoning_delta_text(measurements, metadata) do
    metadata
    |> find_reasoning_delta()
    |> case do
      nil -> find_reasoning_delta(measurements)
      value -> value
    end
    |> normalize_reasoning_text()
  end

  defp find_reasoning_delta(data) when is_map(data) do
    direct_reasoning_keys()
    |> Enum.find_value(&Map.get(data, &1))
    |> case do
      nil -> Enum.find_value(nested_reasoning_paths(), &get_in(data, &1))
      value -> value
    end
  end

  defp find_reasoning_delta(_), do: nil

  defp direct_reasoning_keys do
    [
      :reasoning_delta,
      "reasoning_delta",
      :reasoning,
      "reasoning",
      :delta_reasoning,
      "delta_reasoning"
    ]
  end

  defp nested_reasoning_paths do
    [
      [:delta, :reasoning],
      ["delta", "reasoning"],
      [:delta, :reasoning_delta],
      ["delta", "reasoning_delta"],
      [:output, :reasoning],
      ["output", "reasoning"]
    ]
  end

  defp normalize_reasoning_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_reasoning_text(%{text: text}), do: normalize_reasoning_text(text)
  defp normalize_reasoning_text(%{"text" => text}), do: normalize_reasoning_text(text)

  defp normalize_reasoning_text(list) when is_list(list) do
    text =
      list
      |> Enum.map(&normalize_reasoning_text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    normalize_reasoning_text(text)
  end

  defp normalize_reasoning_text(_), do: nil

  defp prefer_present(new_value, current_value) do
    if empty_value?(new_value), do: current_value, else: new_value
  end

  defp empty_value?(nil), do: true
  defp empty_value?(""), do: true
  defp empty_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp empty_value?(value) when is_map(value), do: map_size(value) == 0
  defp empty_value?(value) when is_list(value), do: value == []
  defp empty_value?(_), do: false

  defp success_event?(event),
    do: event in [[:jido, :ai, :tool, :complete], [:jido, :ai, :tool, :execute, :stop]]

  defp response_time_ms(measurements) when is_map(measurements) do
    Map.get(measurements, :duration_ms) || Map.get(measurements, "duration_ms")
  end

  defp response_time_ms(_), do: nil

  defp extract_tool_params(metadata, measurements) do
    direct = Map.get(metadata, :params) || Map.get(metadata, "params")

    if empty_value?(direct) do
      extract_first(
        [
          metadata,
          measurements
        ],
        [
          :tool_args,
          "tool_args",
          :args,
          "args",
          :params,
          "params",
          :input,
          "input",
          :payload,
          "payload"
        ]
      )
      |> sanitize_payload()
    else
      sanitize_payload(direct)
    end
  end

  defp extract_tool_response(metadata, measurements) do
    direct = Map.get(metadata, :result) || Map.get(metadata, "result")

    if empty_value?(direct) do
      extract_first(
        [
          metadata,
          measurements
        ],
        [
          :tool_result,
          "tool_result",
          :result,
          "result",
          :response,
          "response",
          :output,
          "output",
          :error,
          "error",
          :exception,
          "exception"
        ]
      )
      |> sanitize_payload()
    else
      sanitize_payload(direct)
    end
  end

  defp sanitize_payload(nil), do: nil
  defp sanitize_payload(value) when is_binary(value), do: value
  defp sanitize_payload(value) when is_boolean(value), do: value
  defp sanitize_payload(value) when is_integer(value), do: value
  defp sanitize_payload(value) when is_float(value), do: value

  defp sanitize_payload(value) when is_atom(value), do: Atom.to_string(value)

  defp sanitize_payload(value) when is_list(value) do
    Enum.map(value, &sanitize_payload/1)
  end

  defp sanitize_payload(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize_payload/1)
  end

  defp sanitize_payload(%_{} = value) do
    value
    |> Map.from_struct()
    |> sanitize_payload()
  end

  defp sanitize_payload(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), sanitize_payload(v)} end)
  end

  defp sanitize_payload(value), do: inspect(value)

  defp merge_tool_event_fields(current, metadata, measurements) do
    current
    |> Map.put(:timestamp, prefer_present(Map.get(current, :timestamp), iso8601_now()))
    |> Map.put(
      :params,
      prefer_present(extract_tool_params(metadata, measurements), Map.get(current, :params))
    )
    |> Map.put(
      :response,
      prefer_present(extract_tool_response(metadata, measurements), Map.get(current, :response))
    )
    |> Map.put(
      :response_time_ms,
      prefer_present(response_time_ms(measurements), Map.get(current, :response_time_ms))
    )
  end

  defp extract_first(sources, keys) do
    sources
    |> Enum.filter(&is_map/1)
    |> Enum.find_value(&extract_first_from_source(&1, keys))
  end

  defp extract_first_from_source(source, keys) do
    Enum.find_value(keys, fn key -> Map.get(source, key) end)
  end

  defp request_id(metadata) when is_map(metadata) do
    Map.get(metadata, :request_id) || Map.get(metadata, "request_id")
  end

  defp request_id(_), do: nil

  defp tool_call_id(metadata) when is_map(metadata) do
    (Map.get(metadata, :tool_call_id) || Map.get(metadata, "tool_call_id"))
    |> normalize_tool_call_id()
  end

  defp tool_call_id(_), do: nil

  defp normalize_tool_call_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed in ["", "nil"], do: nil, else: trimmed
  end

  defp normalize_tool_call_id(nil), do: nil
  defp normalize_tool_call_id(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_tool_call_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_tool_call_id(_), do: nil

  defp tool_name(metadata) when is_map(metadata) do
    case Map.get(metadata, :tool_name) || Map.get(metadata, "tool_name") do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  defp tool_name(_), do: nil

  defp new_trace_entry(request_id, tool_call_id, tool_name) do
    %{
      request_id: request_id,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      timestamp: nil,
      params: nil,
      response: nil,
      response_time_ms: nil,
      status: "started"
    }
  end

  defp iso8601_now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end

  defp ensure_trace_table do
    case :ets.whereis(@tool_trace_table) do
      :undefined ->
        :ets.new(@tool_trace_table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        @tool_trace_table
    end
  end

  defp ensure_trace_lock_table do
    case :ets.whereis(@tool_trace_lock_table) do
      :undefined ->
        :ets.new(@tool_trace_lock_table, [:named_table, :public, :set])

      _ ->
        @tool_trace_lock_table
    end
  end

  defp merge_trace(request_id, tool_call_id, tool_name, merge_fn) when is_function(merge_fn, 1) do
    table = ensure_trace_table()
    key = {:tool, request_id, tool_call_id}

    with_trace_lock(key, fn ->
      current =
        case :ets.lookup(table, key) do
          [{^key, trace}] -> trace
          _ -> new_trace_entry(request_id, tool_call_id, tool_name)
        end

      updated = merge_fn.(current)
      :ets.insert(table, {key, updated})
    end)

    :ok
  end

  defp with_trace_lock(key, fun) when is_function(fun, 0) do
    lock_table = ensure_trace_lock_table()
    acquire_trace_lock(lock_table, key, 0)

    try do
      fun.()
    after
      :ets.delete(lock_table, key)
    end
  end

  defp acquire_trace_lock(lock_table, key, attempts) when attempts < 200 do
    if :ets.insert_new(lock_table, {key, true}) do
      :ok
    else
      Process.sleep(1)
      acquire_trace_lock(lock_table, key, attempts + 1)
    end
  end

  defp acquire_trace_lock(lock_table, key, _attempts) do
    :ets.insert(lock_table, {key, true})
    :ok
  end

  defp remember_request_context(request_id) do
    table = ensure_trace_table()

    status_dims =
      Process.get(:zaq_status_context)
      |> proc_ctx_value(:telemetry_dimensions)
      |> normalize_telemetry_dimensions()

    context =
      case Process.get(:zaq_tool_trace_context) do
        %{collector_pid: collector_pid} = tool_trace_ctx when is_pid(collector_pid) ->
          %{
            collector_pid: collector_pid,
            telemetry_dimensions: Map.get(tool_trace_ctx, :telemetry_dimensions, status_dims)
          }

        _ ->
          if map_size(status_dims) > 0 do
            %{telemetry_dimensions: status_dims}
          else
            nil
          end
      end

    if context do
      :ets.insert(table, {{:request_context, request_id}, context})
    end

    :ok
  end

  defp normalize_telemetry_dimensions(dimensions) when is_map(dimensions) do
    dimensions
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_telemetry_dimensions(_), do: %{}

  defp get_request_context(request_id) do
    table = ensure_trace_table()

    case :ets.lookup(table, {:request_context, request_id}) do
      [{{:request_context, ^request_id}, ctx}] -> ctx
      _ -> nil
    end
  end

  defp list_request_traces(request_id) do
    table = ensure_trace_table()

    table
    |> :ets.match({{:tool, request_id, :"$1"}, :"$2"})
    |> Enum.map(fn [tool_call_id, trace] ->
      trace
      |> Map.put_new(:tool_call_id, tool_call_id)
      |> Map.drop([:request_id])
    end)
    |> Enum.sort_by(&Map.get(&1, :timestamp, ""))
  end

  defp clear_request_traces(request_id) do
    table = ensure_trace_table()

    table
    |> :ets.match({{:tool, request_id, :"$1"}, :"$2"})
    |> Enum.each(fn [tool_call_id, _trace] ->
      :ets.delete(table, {:tool, request_id, tool_call_id})
    end)

    :ets.delete(table, {:request_context, request_id})
    :ok
  end

  defp resolve_ctx(metadata) do
    proc_ctx = Process.get(:zaq_status_context)

    session_id = proc_ctx_value(proc_ctx, :session_id) || session_id_from_metadata(metadata)
    request_id = proc_ctx_value(proc_ctx, :request_id)
    node_router = proc_ctx_value(proc_ctx, :node_router) || Zaq.NodeRouter

    with id when is_binary(id) and id != "" <- session_id,
         req when is_binary(req) and req != "" <- request_id do
      %{session_id: id, request_id: req, node_router: node_router}
    else
      _ -> nil
    end
  end

  defp proc_ctx_value(nil, _key), do: nil
  defp proc_ctx_value(proc_ctx, key), do: Map.get(proc_ctx, key)

  defp session_id_from_metadata(metadata) do
    metadata
    |> Map.get(:agent_id)
    |> Factory.spawn_opts_from_server_id()
    |> conversation_id_from_spawn_opts()
  end

  defp conversation_id_from_spawn_opts(%{conversation_id: id}) when is_binary(id) and id != "",
    do: id

  defp conversation_id_from_spawn_opts(_), do: nil

  # defp tool_stage(tool_name) when is_binary(tool_name) do
  #   mcp_prefixes = Application.get_env(:zaq, :mcp_tool_prefixes, @default_mcp_prefixes)

  #   if Enum.any?(mcp_prefixes, &String.starts_with?(tool_name, &1)),
  #     do: :mcp_call,
  #     else: :tool_call
  # end

  # defp tool_stage(_), do: :tool_call
end
