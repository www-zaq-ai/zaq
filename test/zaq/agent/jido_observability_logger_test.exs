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
end
