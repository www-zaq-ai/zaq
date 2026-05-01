defmodule Zaq.Agent.JidoTelemetryBridgeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Zaq.Agent.JidoTelemetryBridge

  defmodule FakeNodeRouter do
    alias Zaq.Event

    def dispatch(%Event{request: %{module: mod, function: fun, args: args}} = event) do
      apply(mod, fun, args)
      event
    end
  end

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
        JidoTelemetryBridge.handle_event(
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
        JidoTelemetryBridge.handle_event(
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
        JidoTelemetryBridge.handle_event(
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
        JidoTelemetryBridge.handle_event(
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
        JidoTelemetryBridge.handle_event(
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
        JidoTelemetryBridge.handle_event(
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
        JidoTelemetryBridge.handle_event(
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
        JidoTelemetryBridge.handle_event(
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
        JidoTelemetryBridge.handle_event(
          [:unknown, :event],
          %{},
          %{request_id: "req-9"},
          %{include_llm_deltas: false, max_payload_chars: 80}
        )
      end)

    assert log =~ "[JidoAI] unknown.event"
  end

  test "terminate callbacks detach only when enabled" do
    assert :ok = JidoTelemetryBridge.terminate(:normal, %{enabled?: true})
    assert :ok = JidoTelemetryBridge.terminate(:normal, %{enabled?: false})
  end

  test "config accepts app env map and non-map fallback" do
    previous = Application.get_env(:zaq, :jido_telemetry_bridge)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:zaq, :jido_telemetry_bridge)
      else
        Application.put_env(:zaq, :jido_telemetry_bridge, previous)
      end
    end)

    Application.put_env(:zaq, :jido_telemetry_bridge, %{
      enabled: true,
      include_llm_deltas: true
    })

    log_with_map =
      capture_log([level: :debug], fn ->
        JidoTelemetryBridge.handle_event(
          [:jido, :ai, :request, :start],
          %{},
          %{request_id: "req-map", payload: [String.duplicate("x", 80)]},
          %{enabled: true, include_llm_deltas: true, max_payload_chars: 20}
        )
      end)

    assert log_with_map =~ "details="
    assert log_with_map =~ "truncated"

    Application.put_env(:zaq, :jido_telemetry_bridge, :invalid)

    log_with_fallback =
      capture_log([level: :info], fn ->
        JidoTelemetryBridge.handle_event(
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
        JidoTelemetryBridge.handle_event(
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
        JidoTelemetryBridge.handle_event(
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
    handler_id = "zaq-agent-jido-telemetry-bridge"
    :telemetry.detach(handler_id)

    previous = Application.get_env(:zaq, :jido_telemetry_bridge)

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if is_nil(previous) do
        Application.delete_env(:zaq, :jido_telemetry_bridge)
      else
        Application.put_env(:zaq, :jido_telemetry_bridge, previous)
      end
    end)

    Application.put_env(:zaq, :jido_telemetry_bridge, %{
      enabled: true,
      include_llm_deltas: true
    })

    assert {:ok, %{enabled?: true}} = JidoTelemetryBridge.init([])
    assert :ok = JidoTelemetryBridge.terminate(:normal, %{enabled?: true})

    Application.put_env(:zaq, :jido_telemetry_bridge, :invalid)
    assert {:ok, %{enabled?: true}} = JidoTelemetryBridge.init([])
    assert :ok = JidoTelemetryBridge.terminate(:normal, %{enabled?: true})
  end

  test "llm.start broadcasts thinking status when context is present" do
    session_id = "bridge-session-#{System.unique_integer([:positive])}"
    request_id = "bridge-req-#{System.unique_integer([:positive])}"

    Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:#{session_id}")

    Process.put(:zaq_status_context, %{
      session_id: session_id,
      request_id: request_id,
      node_router: FakeNodeRouter
    })

    on_exit(fn ->
      Process.delete(:zaq_status_context)
    end)

    assert :ok = JidoTelemetryBridge.handle_event([:jido, :ai, :llm, :start], %{}, %{}, %{})
    assert_receive {:status_update, ^request_id, :answering, "Thinking…"}
  end

  test "tool start broadcasts mcp_call and tracks tool call" do
    previous_prefixes = Application.get_env(:zaq, :mcp_tool_prefixes)
    Application.put_env(:zaq, :mcp_tool_prefixes, ["mcp__"])

    session_id = "bridge-session-#{System.unique_integer([:positive])}"
    request_id = "bridge-req-#{System.unique_integer([:positive])}"

    Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:#{session_id}")

    Process.put(:zaq_status_context, %{
      session_id: session_id,
      request_id: request_id,
      node_router: FakeNodeRouter
    })

    on_exit(fn ->
      Process.delete(:zaq_status_context)

      if is_nil(previous_prefixes) do
        Application.delete_env(:zaq, :mcp_tool_prefixes)
      else
        Application.put_env(:zaq, :mcp_tool_prefixes, previous_prefixes)
      end
    end)

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :start],
               %{},
               %{tool_name: "mcp__read_file"},
               %{}
             )

    assert_receive {:status_update, ^request_id, :retrieving, "Calling mcp__read_file…"}
  end

  test "status broadcast no-ops when status context is incomplete" do
    Process.delete(:zaq_status_context)

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :start],
               %{},
               %{tool_name: "read_file", agent_id: "agent:web:conv:session-1"},
               %{}
             )

    assert Process.get(:zaq_tool_calls) in [nil, []]
  end
end
