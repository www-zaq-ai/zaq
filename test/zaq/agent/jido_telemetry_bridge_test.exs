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

  test "llm.delta broadcasts reasoning as retrieving when enabled" do
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

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :llm, :delta],
               %{},
               %{delta: %{reasoning: "Checking sources"}},
               %{include_llm_deltas: true, max_payload_chars: 80}
             )

    assert_receive {:status_update, ^request_id, :retrieving, "Checking sources"}
  end

  test "llm.delta does not broadcast retrieving when reasoning is missing" do
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

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :llm, :delta],
               %{},
               %{delta: %{content: "Visible answer token"}},
               %{include_llm_deltas: true, max_payload_chars: 80}
             )

    refute_receive {:status_update, ^request_id, :retrieving, _}
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

  test "request completion publishes aggregated tool traces to collector process" do
    request_id = "req-#{System.unique_integer([:positive])}"

    Process.put(:zaq_status_context, %{request_id: request_id})
    Process.put(:zaq_tool_trace_context, %{request_id: request_id, collector_pid: self()})

    on_exit(fn ->
      Process.delete(:zaq_status_context)
      Process.delete(:zaq_tool_trace_context)
    end)

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :start],
               %{},
               %{
                 request_id: request_id,
                 tool_call_id: "tool-1",
                 tool_name: "read_file",
                 args: %{path: "a.txt"}
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :execute, :stop],
               %{duration_ms: 21},
               %{
                 request_id: request_id,
                 tool_call_id: "tool-1",
                 tool_name: "read_file",
                 result: %{ok: true}
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :request, :complete],
               %{},
               %{request_id: request_id},
               %{}
             )

    assert_receive {:zaq_tool_traces, ^request_id, [trace]}
    assert trace.tool_call_id == "tool-1"
    assert trace.tool_name == "read_file"
    assert trace.response_time_ms == 21
    assert trace.status == "ok"
    assert is_binary(trace.timestamp)
  end

  test "later empty payload events do not override existing params/response" do
    request_id = "req-#{System.unique_integer([:positive])}"

    Process.put(:zaq_status_context, %{request_id: request_id})
    Process.put(:zaq_tool_trace_context, %{request_id: request_id, collector_pid: self()})

    on_exit(fn ->
      Process.delete(:zaq_status_context)
      Process.delete(:zaq_tool_trace_context)
    end)

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :execute, :stop],
               %{duration_ms: 1002},
               %{
                 request_id: request_id,
                 tool_call_id: "tool-keep",
                 tool_name: "sleep_action",
                 args: %{"duration_ms" => 1000},
                 result: {:ok, %{duration_ms: 1000}, []}
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :complete],
               %{},
               %{
                 request_id: request_id,
                 tool_call_id: "tool-keep",
                 tool_name: "sleep_action"
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :request, :complete],
               %{},
               %{request_id: request_id},
               %{}
             )

    assert_receive {:zaq_tool_traces, ^request_id, [trace]}
    assert trace.tool_call_id == "tool-keep"
    assert trace.params == %{"duration_ms" => 1000}
    assert trace.response == ["ok", %{"duration_ms" => 1000}, []]
    assert trace.response_time_ms == 1002
  end

  test "keeps params/response scoped per tool_call_id for multiple calls" do
    request_id = "req-#{System.unique_integer([:positive])}"

    Process.put(:zaq_status_context, %{request_id: request_id})
    Process.put(:zaq_tool_trace_context, %{request_id: request_id, collector_pid: self()})

    on_exit(fn ->
      Process.delete(:zaq_status_context)
      Process.delete(:zaq_tool_trace_context)
    end)

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :execute, :start],
               %{duration_ms: 0},
               %{
                 request_id: request_id,
                 tool_call_id: "call-1",
                 tool_name: "sleep_action",
                 params: %{"duration_ms" => 1000}
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :execute, :stop],
               %{duration_ms: 1000},
               %{
                 request_id: request_id,
                 tool_call_id: "call-1",
                 tool_name: "sleep_action",
                 result: {:ok, %{duration_ms: 1000}, []}
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :execute, :start],
               %{duration_ms: 0},
               %{
                 request_id: request_id,
                 tool_call_id: "call-2",
                 tool_name: "sleep_action",
                 params: %{"duration_ms" => 2000}
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :execute, :stop],
               %{duration_ms: 2000},
               %{
                 request_id: request_id,
                 tool_call_id: "call-2",
                 tool_name: "sleep_action",
                 result: {:ok, %{duration_ms: 2000}, []}
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :request, :complete],
               %{},
               %{request_id: request_id},
               %{}
             )

    assert_receive {:zaq_tool_traces, ^request_id, traces}
    assert length(traces) == 2

    trace_1 = Enum.find(traces, &(&1.tool_call_id == "call-1"))
    trace_2 = Enum.find(traces, &(&1.tool_call_id == "call-2"))

    assert trace_1.params == %{"duration_ms" => 1000}
    assert trace_1.response == ["ok", %{"duration_ms" => 1000}, []]
    assert trace_1.response_time_ms == 1000

    assert trace_2.params == %{"duration_ms" => 2000}
    assert trace_2.response == ["ok", %{"duration_ms" => 2000}, []]
    assert trace_2.response_time_ms == 2000
  end

  test "tool.start after tool.execute.start does not wipe params" do
    request_id = "req-#{System.unique_integer([:positive])}"

    Process.put(:zaq_status_context, %{request_id: request_id})
    Process.put(:zaq_tool_trace_context, %{request_id: request_id, collector_pid: self()})

    on_exit(fn ->
      Process.delete(:zaq_status_context)
      Process.delete(:zaq_tool_trace_context)
    end)

    call_id = "chatcmpl-tool-ordered-1"

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :execute, :start],
               %{duration_ms: 0},
               %{
                 request_id: request_id,
                 tool_call_id: call_id,
                 tool_name: "sleep_action",
                 params: %{"duration_ms" => 1000}
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :start],
               %{duration_ms: 0},
               %{
                 request_id: request_id,
                 tool_call_id: call_id,
                 tool_name: "sleep_action"
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :execute, :stop],
               %{duration_ms: 1000},
               %{
                 request_id: request_id,
                 tool_call_id: call_id,
                 tool_name: "sleep_action",
                 result: {:ok, %{duration_ms: 1000}, []}
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :complete],
               %{duration_ms: 1002},
               %{
                 request_id: request_id,
                 tool_call_id: call_id,
                 tool_name: "sleep_action"
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :request, :complete],
               %{},
               %{request_id: request_id},
               %{}
             )

    assert_receive {:zaq_tool_traces, ^request_id, [trace]}
    assert trace.tool_call_id == call_id
    assert trace.params == %{"duration_ms" => 1000}
    assert trace.response == ["ok", %{"duration_ms" => 1000}, []]
    assert trace.response_time_ms == 1002
    assert is_binary(trace.timestamp)
  end

  test "request completion does not publish when ctx request_id is missing even if metadata has request_id" do
    request_id = "req-#{System.unique_integer([:positive])}"

    Process.delete(:zaq_status_context)
    Process.put(:zaq_tool_trace_context, %{request_id: request_id, collector_pid: self()})

    on_exit(fn ->
      Process.delete(:zaq_tool_trace_context)
    end)

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :start],
               %{},
               %{request_id: request_id, tool_call_id: "tool-1", tool_name: "read_file"},
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :request, :complete],
               %{},
               %{request_id: request_id},
               %{}
             )

    refute_receive {:zaq_tool_traces, _, _}
  end

  test "request terminal events with blank request_id metadata no-op" do
    request_id = "req-#{System.unique_integer([:positive])}"

    Process.put(:zaq_status_context, %{request_id: request_id})
    Process.put(:zaq_tool_trace_context, %{request_id: request_id, collector_pid: self()})

    on_exit(fn ->
      Process.delete(:zaq_status_context)
      Process.delete(:zaq_tool_trace_context)
    end)

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :request, :complete],
               %{},
               %{request_id: ""},
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :request, :failed],
               %{},
               %{},
               %{}
             )

    refute_receive {:zaq_tool_traces, _, _}
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

  test "init logs warning and disables bridge when telemetry handler already attached" do
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

    Application.put_env(:zaq, :jido_telemetry_bridge, %{enabled: true})

    assert {:ok, %{enabled?: true}} = JidoTelemetryBridge.init([])

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, %{enabled?: false}} = JidoTelemetryBridge.init([])
      end)

    assert log =~ "telemetry attach failed"
  end

  test "llm.delta reasoning extraction supports fallback map/list forms" do
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

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :llm, :delta],
               %{reasoning: %{text: "from measurements"}},
               %{},
               %{include_llm_deltas: true}
             )

    assert_receive {:status_update, ^request_id, :retrieving, "from measurements"}

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :llm, :delta],
               %{},
               %{delta: %{reasoning: [%{"text" => "part"}, " ", "two"]}},
               %{include_llm_deltas: true}
             )

    assert_receive {:status_update, ^request_id, :retrieving, "part two"}
  end

  test "tool trace keeps prior values when new values are empty and handles non-map measurements" do
    request_id = "req-#{System.unique_integer([:positive])}"

    Process.put(:zaq_status_context, %{request_id: request_id})
    Process.put(:zaq_tool_trace_context, %{request_id: request_id, collector_pid: self()})

    on_exit(fn ->
      Process.delete(:zaq_status_context)
      Process.delete(:zaq_tool_trace_context)
    end)

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :start],
               %{duration_ms: 11},
               %{
                 request_id: request_id,
                 tool_call_id: "tool-empty",
                 tool_name: :read_file,
                 params: %{
                   path: "a.txt",
                   ratio: 1.2
                 }
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :execute, :stop],
               %{},
               %{
                 request_id: request_id,
                 tool_call_id: 7,
                 tool_name: :read_file,
                 params: "",
                 result: ""
               },
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :request, :complete],
               %{},
               %{request_id: request_id},
               %{}
             )

    assert_receive {:zaq_tool_traces, ^request_id, traces}
    trace = Enum.find(traces, &(&1.tool_call_id == "tool-empty"))
    assert trace != nil

    assert trace.tool_name == "read_file"
    assert trace.params["ratio"] == 1.2
    assert trace.params["path"] == "a.txt"
    assert trace.response_time_ms == 11
  end

  test "invalid tool ids and names are ignored and publish empty traces" do
    request_id = "req-#{System.unique_integer([:positive])}"

    Process.put(:zaq_status_context, %{request_id: request_id})
    Process.put(:zaq_tool_trace_context, %{request_id: request_id, collector_pid: self()})

    on_exit(fn ->
      Process.delete(:zaq_status_context)
      Process.delete(:zaq_tool_trace_context)
    end)

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :tool, :start],
               %{},
               %{request_id: request_id, tool_call_id: [], tool_name: 99},
               %{}
             )

    assert :ok =
             JidoTelemetryBridge.handle_event(
               [:jido, :ai, :request, :complete],
               %{},
               %{request_id: request_id},
               %{}
             )

    assert_receive {:zaq_tool_traces, ^request_id, traces}
    assert traces == []
  end
end
