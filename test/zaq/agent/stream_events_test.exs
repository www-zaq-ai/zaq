defmodule Zaq.Agent.StreamEventsTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.StreamEvents
  alias Zaq.Engine.Messages.Incoming

  defmodule FakeStatus do
    def broadcast(incoming, stage, message, _node_router, opts) do
      send(self(), {:broadcast, stage, message, Keyword.get(opts, :update_intent)})
      put_in(incoming.metadata[:status_message_id], incoming.metadata[:request_id])
    end
  end

  test "coalesces small deltas and flushes the full content on terminal event" do
    incoming = incoming()

    events = [
      event(:llm_delta, 10, %{chunk_type: :content, delta: "hello ", model: "openai:gpt-4o-mini"}),
      event(:llm_delta, 20, %{chunk_type: :content, delta: "world", model: "openai:gpt-4o-mini"}),
      event(:request_completed, 30, %{
        result: "hello world",
        usage: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
      })
    ]

    assert {:ok, result} =
             StreamEvents.consume(events, incoming,
               status_module: FakeStatus,
               agent: %{id: 42, name: "Answering"}
             )

    assert result.answer == "hello world"
    assert result.usage == %{input_tokens: 1, output_tokens: 2, total_tokens: 3}

    assert [%{"id" => "llm-1", "type" => "content", "turn_id" => "0"} = trace_entry] =
             result.trace

    refute Map.has_key?(trace_entry, "content")

    assert result.measurements["total_tokens"] == 3
    assert result.measurements["prompt_tokens"] == 1
    assert result.measurements["completion_tokens"] == 2
    assert result.measurements["input_tokens"] == 1
    assert result.measurements["output_tokens"] == 2
    assert result.measurements["turn_count"] == 1
    assert result.measurements["llm_call_count"] == 1
    assert result.model == "openai:gpt-4o-mini"
    assert result.agent == %{id: 42, name: "Answering"}
    assert_receive {:broadcast, :answering, "hello world", :stream_delta}
    refute_receive {:broadcast, _, _, _}
  end

  test "flushes when chunk type changes and stores thinking as reasoning trace" do
    incoming = incoming()

    events = [
      event(:llm_delta, 150, %{chunk_type: :thinking, delta: "I should search first."}),
      event(:llm_delta, 300, %{chunk_type: :content, delta: "The answer is 42."}),
      event(:request_completed, 350, %{result: "The answer is 42."})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming, status_module: FakeStatus)

    assert [
             %{"type" => "reasoning", "content" => "I should search first."},
             %{"type" => "content"} = content_entry
           ] = result.trace

    refute Map.has_key?(content_entry, "content")

    assert_receive {:broadcast, :thinking, "I should search first.", :reasoning}
    assert_receive {:broadcast, :answering, "The answer is 42.", :stream_delta}
  end

  test "json_safe converts non-json values before trace persistence" do
    value = %{
      ok_tuple: {:ok, %{ref: make_ref()}},
      at: ~U[2026-06-11 10:00:00Z],
      nested: %{self: self()}
    }

    safe = StreamEvents.json_safe(value)

    assert Jason.encode!(safe)
    assert safe["ok_tuple"] |> is_list()
    assert safe["at"] == "2026-06-11T10:00:00Z"
    assert is_binary(safe["nested"]["self"])
  end

  test "captures tool calls in trace and result" do
    incoming = incoming()

    events = [
      event(:tool_started, 10, %{tool_name: "search", arguments: %{query: "zaq"}},
        tool_call_id: "tool-1"
      ),
      event(:tool_completed, 20, %{tool_name: "search", result: %{hits: 2}, duration_ms: 10},
        tool_call_id: "tool-1"
      ),
      event(:request_completed, 30, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming, status_module: FakeStatus)

    assert [%{"id" => "tool-1", "response" => %{"hits" => 2}}] = result.tool_calls

    assert [%{"id" => "tool-1", "type" => "tool_call", "response" => %{"hits" => 2}}] =
             result.trace

    assert result.measurements["tool_call_count"] == 1
    assert_receive {:broadcast, :tool_call, "Using search", :tool_call}
    assert_receive {:broadcast, :tool_call, "Finished search", :tool_call}
  end

  describe "terminal events" do
    test "returns cancelled result and registers cancellation" do
      incoming = incoming()

      events = [
        event(:llm_delta, 10, %{chunk_type: :content, delta: "partial"}),
        event(:request_cancelled, 20, %{reason: "user stopped"})
      ]

      assert {:ok, result} =
               StreamEvents.consume(events, incoming, status_module: FakeStatus)

      assert result.answer == "partial"
      assert result.termination_reason == :cancelled
      assert [%{"type" => "content"}] = result.trace
      assert_receive {:broadcast, :answering, "partial", :stream_delta}
    end
  end

  test "uses message_id as request id when metadata is not a map" do
    incoming = %Incoming{
      content: "question",
      channel_id: "chan-1",
      provider: :web,
      message_id: "msg-1",
      metadata: nil
    }

    events = [event(:request_completed, 30, %{result: "done"})]

    assert {:ok, result} = StreamEvents.consume(events, incoming, status_module: FakeStatus)

    assert result.answer == "done"
    assert result.incoming.message_id == "msg-1"
  end

  test "omits trace timestamps and duration when event timing is missing" do
    events = [
      %{
        kind: :llm_delta,
        data: %{chunk_type: :thinking, delta: "thinking"},
        iteration: 0,
        llm_call_id: nil
      },
      %{kind: :request_completed, data: %{result: "done"}}
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [%{"type" => "reasoning", "content" => "thinking"} = trace] = result.trace
    refute Map.has_key?(trace, "started_at")
    refute Map.has_key?(trace, "started_at_ms")
    refute Map.has_key?(trace, "ended_at")
    refute Map.has_key?(trace, "ended_at_ms")
    refute Map.has_key?(trace, "duration_ms")
  end

  test "accepts string-keyed tool events and struct-like event timestamps" do
    events = [
      %{
        "id" => "tool-string",
        "kind" => :tool_started,
        "at_ms" => 1_765_411_200_000,
        "iteration" => 1,
        "tool_call_id" => "tool-string",
        "data" => %{"tool_name" => "lookup", "arguments" => %{"q" => "zaq"}}
      },
      %{
        "id" => "tool-string",
        "kind" => :tool_completed,
        "at_ms" => 1_765_411_200_050,
        "iteration" => 1,
        "tool_call_id" => "tool-string",
        "data" => %{
          "tool_name" => "lookup",
          "result" => %{"ok" => true},
          "duration_ms" => 50
        }
      },
      event(:request_completed, 30, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [%{"id" => "tool-string", "started_at" => started, "ended_at" => ended}] =
             result.trace

    assert is_binary(started)
    assert is_binary(ended)
    assert [%{"duration_ms" => 50}] = result.tool_calls
  end

  test "drops invalid unix millisecond timestamps" do
    events = [
      event(:tool_started, 99_999_999_999_999_999_999, %{tool_name: "lookup"}),
      event(:request_completed, 1, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [%{"id" => _} = tool] = result.tool_calls
    assert is_nil(tool["started_at"])
    assert tool["started_at_ms"] == 99_999_999_999_999_999_999
  end

  test "normalizes string chunk types" do
    events = [
      event(:llm_delta, 10, %{chunk_type: "thinking", delta: "reason"}),
      event(:llm_delta, 120, %{chunk_type: "content", delta: "answer"}),
      event(:request_completed, 130, %{result: "answer"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [%{"type" => "reasoning"}, %{"type" => "content"}] = result.trace
    assert_receive {:broadcast, :thinking, "reason", :reasoning}
    assert_receive {:broadcast, :answering, "answer", :stream_delta}
  end

  test "ignores malformed non-map events" do
    events = [
      :not_an_event,
      event(:request_completed, 10, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert result.answer == "done"
  end

  test "json_safe converts date/time, floats, opaque values, and non-string map keys" do
    pid = self()
    ref = make_ref()

    value = %{
      {:tuple, :key} => pid,
      123 => :number_key,
      date: ~D[2026-06-11],
      naive: ~N[2026-06-11 10:00:00],
      time: ~T[10:00:00],
      float: 1.5,
      opaque: %{pid: pid, ref: ref}
    }

    safe = StreamEvents.json_safe(value)

    assert safe["date"] == "2026-06-11"
    assert safe["naive"] == "2026-06-11T10:00:00"
    assert safe["time"] == "10:00:00"
    assert safe["float"] == 1.5
    assert is_binary(safe["{:tuple, :key}"])
    assert safe["123"] == "number_key"
    assert is_binary(safe["opaque"]["pid"])
    assert is_binary(safe["opaque"]["ref"])
    assert Jason.encode!(safe)
  end

  test "json_safe falls back to inspect when sanitized value still cannot encode" do
    safe = StreamEvents.json_safe(%{bad: <<255>>})

    assert Jason.encode!(safe)
  end

  defp incoming do
    %Incoming{
      content: "question",
      channel_id: "chan-1",
      provider: :web,
      metadata: %{request_id: "req-1", session_id: "sess-1"}
    }
  end

  defp event(kind, at_ms, data, attrs \\ []) do
    %{
      id: "evt-#{at_ms}",
      seq: at_ms,
      at_ms: at_ms,
      run_id: "run-1",
      request_id: "req-1",
      iteration: 0,
      kind: kind,
      llm_call_id: "llm-1",
      tool_call_id: Keyword.get(attrs, :tool_call_id),
      tool_name: Map.get(data, :tool_name),
      data: data
    }
  end
end
