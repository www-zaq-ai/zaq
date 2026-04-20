defmodule Zaq.Agent.JidoObservabilityLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Zaq.Agent.JidoObservabilityLogger

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  test "info level logs lifecycle summary without payload details" do
    log =
      capture_log([level: :info], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :request, :start],
          %{duration_ms: 12},
          %{
            request_id: "req-1",
            run_id: "run-1",
            input: %{"api_key" => "secret", "message" => "hello"}
          },
          %{include_llm_deltas: false, max_payload_chars: 80}
        )
      end)

    assert log =~ "[JidoAI] request.start"
    assert log =~ "request_id=req-1"
    refute log =~ "api_key"
    refute log =~ "details="
  end

  test "debug level includes sanitized and truncated details" do
    long_text = String.duplicate("x", 120)

    log =
      capture_log([level: :debug], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :request, :complete],
          %{duration_ms: 42, total_tokens: 77},
          %{
            request_id: "req-2",
            output: %{response: long_text},
            api_key: "top-secret"
          },
          %{include_llm_deltas: false, max_payload_chars: 20}
        )
      end)

    assert log =~ "[JidoAI] request.complete"
    assert log =~ "details="
    assert log =~ "[REDACTED]"
    assert log =~ "...(truncated"
  end

  test "llm delta events are skipped when disabled" do
    log =
      capture_log([level: :debug], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :llm, :delta],
          %{},
          %{request_id: "req-3", delta: "partial token"},
          %{include_llm_deltas: false, max_payload_chars: 80}
        )
      end)

    assert log == ""
  end

  test "tool errors are logged at error level" do
    log =
      capture_log([level: :error], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :tool, :error],
          %{duration_ms: 9},
          %{tool_name: "read_file", request_id: "req-4", error_type: :timeout},
          %{include_llm_deltas: false, max_payload_chars: 80}
        )
      end)

    assert log =~ "[JidoAI] tool.error"
    assert log =~ "tool_name=read_file"
    assert log =~ "error_type=:timeout"
  end

  test "tool timeout events are logged at warning level" do
    log =
      capture_log([level: :warning], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :tool, :timeout],
          %{duration_ms: 15},
          %{tool_name: "read_file", request_id: "req-5", error_type: :timeout},
          %{include_llm_deltas: false, max_payload_chars: 80}
        )
      end)

    assert log =~ "[JidoAI] tool.timeout"
    assert log =~ "tool_name=read_file"
  end

  test "llm delta events are logged when enabled" do
    log =
      capture_log([level: :info], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :llm, :delta],
          %{},
          %{request_id: "req-6", model: "gpt-4.1-mini"},
          %{include_llm_deltas: true, max_payload_chars: 80}
        )
      end)

    assert log =~ "[JidoAI] llm.delta"
    assert log =~ "request_id=req-6"
  end

  test "non-map callback config falls back to defaults" do
    log =
      capture_log([level: :debug], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :request, :complete],
          %{duration_ms: 1},
          %{request_id: "req-7", output: %{text: String.duplicate("x", 100)}},
          :invalid
        )
      end)

    assert log =~ "[JidoAI] request.complete"
    assert log =~ "details="
  end

  test "tool execute exception uses tool.execute event naming" do
    log =
      capture_log([level: :error], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :tool, :execute, :exception],
          %{duration_ms: 3},
          %{request_id: "req-8", tool_name: "read_file", error_type: :boom},
          %{include_llm_deltas: false, max_payload_chars: 80}
        )
      end)

    assert log =~ "[JidoAI] tool.execute.exception"
    assert log =~ "error_type=:boom"
  end

  test "unknown telemetry event uses fallback event name formatter" do
    log =
      capture_log([level: :info], fn ->
        JidoObservabilityLogger.handle_event(
          [:unknown, :event],
          %{},
          %{request_id: "req-9"},
          %{include_llm_deltas: false, max_payload_chars: 80}
        )
      end)

    assert log =~ "[JidoAI] unknown.event"
  end

  test "terminate callbacks detach only when enabled" do
    assert :ok = JidoObservabilityLogger.terminate(:normal, %{enabled?: true})
    assert :ok = JidoObservabilityLogger.terminate(:normal, %{enabled?: false})
  end

  test "config accepts app env map and non-map fallback" do
    previous = Application.get_env(:zaq, :jido_observability_logger)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:zaq, :jido_observability_logger)
      else
        Application.put_env(:zaq, :jido_observability_logger, previous)
      end
    end)

    Application.put_env(:zaq, :jido_observability_logger, %{
      enabled: true,
      include_llm_deltas: true
    })

    log_with_map =
      capture_log([level: :debug], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :request, :start],
          %{},
          %{request_id: "req-map", payload: [String.duplicate("x", 80)]},
          %{enabled: true, include_llm_deltas: true, max_payload_chars: 20}
        )
      end)

    assert log_with_map =~ "details="
    assert log_with_map =~ "truncated"

    Application.put_env(:zaq, :jido_observability_logger, :invalid)

    log_with_fallback =
      capture_log([level: :info], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :request, :start],
          %{},
          %{},
          %{}
        )
      end)

    assert log_with_fallback =~ "[JidoAI] request.start"
  end

  test "llm error events are logged at error level" do
    log =
      capture_log([level: :error], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :llm, :error],
          %{},
          %{request_id: "req-llm-error", error_type: :rate_limited},
          %{include_llm_deltas: false, max_payload_chars: 80}
        )
      end)

    assert log =~ "[JidoAI] llm.error"
    assert log =~ "error_type=:rate_limited"
  end

  test "request failed events are logged at error level" do
    log =
      capture_log([level: :error], fn ->
        JidoObservabilityLogger.handle_event(
          [:jido, :ai, :request, :failed],
          %{duration_ms: 10},
          %{request_id: "req-failed", error_type: :upstream},
          %{include_llm_deltas: false, max_payload_chars: 80}
        )
      end)

    assert log =~ "[JidoAI] request.failed"
    assert log =~ "error_type=:upstream"
  end

  test "init reads map and fallback config shapes" do
    handler_id = "zaq-agent-jido-observability-logger"
    :telemetry.detach(handler_id)

    previous = Application.get_env(:zaq, :jido_observability_logger)

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if is_nil(previous) do
        Application.delete_env(:zaq, :jido_observability_logger)
      else
        Application.put_env(:zaq, :jido_observability_logger, previous)
      end
    end)

    Application.put_env(:zaq, :jido_observability_logger, %{
      enabled: true,
      include_llm_deltas: true
    })

    assert {:ok, %{enabled?: true}} = JidoObservabilityLogger.init([])
    assert :ok = JidoObservabilityLogger.terminate(:normal, %{enabled?: true})

    Application.put_env(:zaq, :jido_observability_logger, :invalid)
    assert {:ok, %{enabled?: true}} = JidoObservabilityLogger.init([])
    assert :ok = JidoObservabilityLogger.terminate(:normal, %{enabled?: true})
  end
end
