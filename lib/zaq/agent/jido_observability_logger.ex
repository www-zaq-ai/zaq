defmodule Zaq.Agent.JidoObservabilityLogger do
  @moduledoc """
  Logs Jido AI telemetry events with level-aware detail.
  """

  use GenServer

  require Logger

  alias Jido.AI.Observe

  @handler_id "zaq-agent-jido-observability-logger"

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

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    cfg = config()

    if cfg.enabled do
      :ok =
        :telemetry.attach_many(
          @handler_id,
          events(cfg.include_llm_deltas),
          &__MODULE__.handle_event/4,
          cfg
        )
    end

    {:ok, %{enabled?: cfg.enabled}}
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
      case Application.get_env(:zaq, :jido_observability_logger, %{}) do
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
end
