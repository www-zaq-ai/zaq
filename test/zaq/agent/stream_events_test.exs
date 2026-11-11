defmodule Zaq.Agent.StreamEventsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.AI.Request.Handle
  alias Jido.AI.Request.Stream, as: RequestStream
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolResult
  alias Zaq.Agent.{Factory, OpaqueAliases, StreamEvents}
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.Messages.Incoming

  defmodule FakeStatus do
    def broadcast(incoming, stage, message, _node_router, opts) do
      send(self(), {:broadcast, stage, message, Keyword.get(opts, :update_intent)})
      put_in(incoming.metadata[:status_message_id], incoming.metadata[:request_id])
    end
  end

  defmodule StructEvent do
    defstruct [:kind, :at_ms, :iteration, :tool_call_id, :tool_name, :data]
  end

  defmodule StreamEventWithoutTimestamp do
    defstruct [:kind, :iteration, :tool_call_id, :tool_name, :data]
  end

  defmodule JsonStruct do
    defstruct [:name]
  end

  defmodule SnapshotStatus do
    def broadcast(incoming, stage, message, _router, opts) do
      send(self(), {:snapshot, stage, message, Keyword.get(opts, :tool_steps)})
      incoming
    end
  end

  property "native streams isolate interleaved attachment and terminal events by handle ID" do
    check all(
            [request_id, other_id] <-
              uniq_list_of(string(:alphanumeric, min_length: 1), length: 2)
          ) do
      request = %Handle{id: request_id, server: self(), query: "question"}
      other_request = %Handle{id: other_id, server: self(), query: "other question"}

      events = [
        event(:tool_completed, 1, %{tool_name: "attach_documents", result: {:ok, nil, []}},
          tool_call_id: "other-attachment"
        )
        |> Map.put(:request_id, other_id),
        event(:request_failed, 2, %{error: :other_request_failure})
        |> Map.put(:request_id, other_id),
        event(:request_completed, 3, %{result: "The requested answer."})
        |> Map.put(:request_id, request_id)
      ]

      Enum.each(events, &RequestStream.send_event({:pid, self()}, &1))

      assert {:ok,
              %{
                answer: "The requested answer.",
                attachments: [],
                attachment_error: nil,
                tool_calls: []
              }} =
               StreamEvents.consume(
                 RequestStream.events(request, stream_event_timeout_ms: 100),
                 incoming(),
                 request: request,
                 status_module: FakeStatus
               )

      assert {:error, :other_request_failure, %{attachment_error: :invalid_attachment_selection}} =
               StreamEvents.consume(
                 RequestStream.events(other_request, stream_event_timeout_ms: 100),
                 incoming(),
                 request: other_request,
                 status_module: FakeStatus
               )
    end
  end

  for {scenario, output} <- [
        {"rejected instruction", %{operation: "unsupported", records: []}},
        {"malformed output", "not an attachment instruction"}
      ] do
    @attachment_output output

    test "preserves a completed answer after attachment selection receives #{scenario}" do
      completion = event(:request_completed, 3, %{result: "Here is your summary."})

      assert {:ok, %{answer: "Here is your summary.", attachments: []}} =
               StreamEvents.consume([completion], incoming(), status_module: FakeStatus)

      events = [
        event(:tool_started, 1, %{tool_name: "attach_documents"}, tool_call_id: "attachment-1"),
        event(
          :tool_completed,
          2,
          %{tool_name: "attach_documents", result: {:ok, @attachment_output, []}},
          tool_call_id: "attachment-1"
        ),
        completion
      ]

      assert {:ok, %{answer: "Here is your summary.", attachments: []}} =
               StreamEvents.consume(events, incoming(), status_module: FakeStatus)
    end
  end

  property "malformed attachment outputs preserve arbitrary completed answers with a separate failure" do
    check all(
            answer <- string(:printable, min_length: 1),
            output <- one_of([integer(), string(:printable), list_of(integer()), constant(nil)])
          ) do
      events = [
        event(:tool_completed, 1, %{tool_name: "attach_documents", result: {:ok, output, []}},
          tool_call_id: "invalid-selection"
        ),
        event(:request_completed, 2, %{result: answer})
      ]

      assert {:ok,
              %{
                answer: ^answer,
                attachments: [],
                attachment_error: :invalid_attachment_selection
              }} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)
    end
  end

  test "a valid selection instruction clears a prior selection error" do
    events = [
      event(:tool_completed, 1, %{tool_name: "attach_documents", result: {:ok, nil, []}},
        tool_call_id: "invalid-selection"
      ),
      event(
        :tool_completed,
        2,
        %{tool_name: "attach_documents", result: {:ok, %{operation: "replace", records: []}, []}},
        tool_call_id: "corrected-selection"
      ),
      event(:request_completed, 3, %{result: "No files needed."})
    ]

    assert {:ok, %{answer: "No files needed.", attachments: [], attachment_error: nil}} =
             StreamEvents.consume(events, incoming(),
               status_module: FakeStatus,
               opaque_alias_scope: self()
             )
  end

  test "output validation failure preserves the answer when an alias scope is available" do
    events = [
      event(
        :tool_completed,
        1,
        %{
          tool_name: "attach_documents",
          result: {:ok, %{operation: "unsupported", records: []}, []}
        },
        tool_call_id: "invalid-selection"
      ),
      event(:request_completed, 2, %{result: "Here is your summary."})
    ]

    assert {:ok,
            %{
              answer: "Here is your summary.",
              attachments: [],
              attachment_error: :invalid_attachment_selection
            }} =
             StreamEvents.consume(events, incoming(),
               status_module: FakeStatus,
               opaque_alias_scope: self()
             )
  end

  test "attachment selection failure does not hide a genuine request failure" do
    events = [
      event(:tool_completed, 1, %{tool_name: "attach_documents", result: {:ok, nil, []}},
        tool_call_id: "invalid-selection"
      ),
      event(:request_failed, 2, %{error: :provider_unavailable})
    ]

    assert {:error, :provider_unavailable, %{attachments: []}} =
             StreamEvents.consume(events, incoming(), status_module: FakeStatus)
  end

  test "nested diagnostics retain hierarchy but cannot publish labels, sources or root counts" do
    hierarchy = %{origin: "zaq_action", invocation_path: ["root", "child"], parent_id: "root"}

    start =
      event(:tool_started, 1, Map.put(hierarchy, :arguments, %{value: 42}), tool_call_id: "child")

    done =
      event(
        :tool_completed,
        2,
        Map.merge(hierarchy, %{
          outcome: "failed",
          result: {:error, %{sources: ["private.md"]}, []}
        }),
        tool_call_id: "child"
      )

    root =
      event(:tool_completed, 3, %{result: {:ok, %{sources: ["public.md"]}, []}},
        tool_call_id: "root"
      )

    events = [start, done, done, start, root, event(:request_completed, 4, %{result: "done"})]
    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: SnapshotStatus)
    assert [child, _root] = result.tool_calls
    assert child["invocation_path"] == ["root", "child"]
    assert child["parent_id"] == "root"
    assert child["outcome"] == "failed"
    assert result.sources == ["public.md"]
    assert result.measurements["tool_call_count"] == 1
    refute_received {:snapshot, :tool_call, "Using tool", _}
  end

  test "nested document results use existing artifact storage without inline trace bytes" do
    record = %Record{
      id: "document",
      kind: :document,
      name: "example",
      content: Base.encode64("raw bytes"),
      attributes: %{"encoding" => "base64"}
    }

    for payload <- [record, %{record: record}, %ToolResult{output: %{record: record}}] do
      data = %{
        origin: "zaq_action",
        invocation_path: ["root", "child"],
        parent_id: "root",
        result: {:ok, payload, []},
        outcome: "succeeded"
      }

      events = [
        event(:tool_completed, 1, data, tool_call_id: "child"),
        event(:request_completed, 2, %{result: "done"})
      ]

      assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)
      assert [%{content: "raw bytes", tool_call_id: "child"}] = result.trace_artifacts
      refute Jason.encode!(result.trace) =~ record.content
      refute Jason.encode!(result.trace) =~ "raw bytes"
    end
  end

  test "rootless descendants retain the observed parent's turn" do
    parent = %{
      origin: "zaq_action",
      invocation_path: ["absent-root", "parent"],
      parent_id: "absent-root",
      arguments: %{}
    }

    child = %{
      origin: "zaq_action",
      invocation_path: ["absent-root", "parent", "child"],
      parent_id: "parent",
      arguments: %{}
    }

    events = [
      event(:tool_started, 1, parent, tool_call_id: "parent", iteration: 7),
      event(:tool_started, 2, child, tool_call_id: "child", iteration: 0),
      event(:request_completed, 3, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)
    assert Enum.map(result.tool_calls, & &1["turn_id"]) == ["7", "7"]
    assert Enum.map(result.trace, & &1["turn_id"]) == ["7", "7"]
  end

  property "final native-root turn attribution is independent of descendant arrival order" do
    check all(turn <- integer(1..100), order <- member_of([:root_first, :child_first])) do
      root = event(:tool_started, 1, %{arguments: %{}}, tool_call_id: "root", iteration: turn)

      child =
        event(
          :tool_started,
          2,
          %{origin: "zaq_action", invocation_path: ["root", "child"], parent_id: "root"},
          tool_call_id: "child",
          iteration: 0
        )

      calls = if order == :root_first, do: [root, child], else: [child, root]
      events = calls ++ [event(:request_completed, 3, %{result: "done"})]
      assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)
      assert Enum.all?(result.tool_calls, &(&1["turn_id"] == to_string(turn)))
      assert Enum.all?(result.trace, &(&1["turn_id"] == to_string(turn)))
    end
  end

  test "declared sources accumulate per request without inspecting chunks or permissions" do
    completed = fn id, result ->
      event(:tool_completed, 1, %{tool_name: "knowledge", result: result}, tool_call_id: id)
    end

    first =
      completed.(
        "a",
        {:ok,
         %{
           sources: ["public.md", "denied.md", "public.md"],
           chunks: [%{"source" => "not-declared.md"}]
         }, []}
      )

    events = [
      first,
      first,
      completed.(
        "b",
        {:ok, %ToolResult{output: %{"sources" => ["other.md", "denied.md", "", nil, 42]}}, []}
      ),
      completed.("c", {:error, %{sources: ["failed.md"]}, []}),
      completed.("d", {:ok, %{chunks: [%{"source" => "implicit.md"}]}, []}),
      event(:request_completed, 2, %{result: "Cited [[source:denied.md]]"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)
    assert result.sources == ["public.md", "denied.md", "other.md"]
    assert {:ok, next} = StreamEvents.consume([], incoming(), status_module: FakeStatus)
    assert next.sources == []
  end

  property "source union is stable under repeated completions" do
    check all(
            paths <- list_of(string(:alphanumeric, min_length: 1, max_length: 20), max_length: 15)
          ) do
      events =
        for {path, index} <- Enum.with_index(paths) do
          event(:tool_completed, index, %{result: {:ok, %{sources: [path]}}},
            tool_call_id: "call-#{index}"
          )
        end

      assert {:ok, result} =
               StreamEvents.consume(events ++ events, incoming(), status_module: FakeStatus)

      assert result.sources == Enum.uniq(paths)
    end
  end

  test "settles snapshots in evidence without forcing publication and suppresses public step replay" do
    start = event(:tool_started, 1, %{tool_name: "search"}, tool_call_id: "a")
    events = [start, start, event(:request_failed, 2, %{error: {:react_worker_exit, :killed}})]

    assert {:error, _, result} =
             StreamEvents.consume(events, incoming(), status_module: SnapshotStatus)

    assert_receive {:snapshot, :tool_call, "Using search", [%{"state" => "running"}]}
    assert [%{"state" => "unknown"}] = public_steps(result)
    refute_receive {:snapshot, _, _, _}
  end

  test "public snapshots order invocations rather than names and classify native completions" do
    events = [
      event(:tool_started, 1, %{tool_name: "search", arguments: %{secret: "private"}},
        tool_call_id: "a"
      ),
      event(:tool_started, 2, %{tool_name: "search"}, tool_call_id: "b"),
      event(
        :tool_completed,
        3,
        %{tool_name: "search", result: {:error, :denied, []}, duration_ms: 2},
        tool_call_id: "b"
      ),
      event(:tool_completed, 4, %{tool_name: "search", result: {:ok, %{secret: "private"}, []}},
        tool_call_id: "a"
      ),
      event(:request_completed, 5, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [
             %{"id" => "a", "sequence" => 1, "state" => "succeeded"},
             %{"id" => "b", "sequence" => 2, "state" => "failed", "duration_ms" => 2}
           ] = public_steps(result)

    refute Jason.encode!(public_steps(result)) =~ "private"
    assert Enum.any?(result.tool_calls, &(&1["arguments"] == %{"secret" => "private"}))

    assert ToolStep.project(result.trace) == public_steps(result)
    assert ToolStep.project(Jason.decode!(Jason.encode!(result.trace))) == public_steps(result)
  end

  test "request failure preserves completions and settles only outstanding starts to unknown" do
    events = [
      event(:tool_started, 1, %{tool_name: "search"}, tool_call_id: "pending"),
      event(:tool_completed, 2, %{tool_name: "search", result: {:ok, "done"}},
        tool_call_id: "ok"
      ),
      event(:tool_completed, 3, %{tool_name: "search", result: {:error, :denied}},
        tool_call_id: "error"
      ),
      event(:request_failed, 4, %{error: {:react_worker_exit, :killed}})
    ]

    assert {:error, {:react_worker_exit, :killed}, result} =
             StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert Enum.map(public_steps(result), & &1["state"]) == ["unknown", "succeeded", "failed"]
    assert ToolStep.project(result.trace) == public_steps(result)
  end

  test "public identity never falls back to event IDs or malformed invocation IDs" do
    events =
      Enum.map([nil, "", 42, String.duplicate("a", 257)], fn id ->
        event(:tool_started, 1, %{tool_name: "search"}, tool_call_id: id)
      end) ++ [event(:request_completed, 2, %{result: "done"})]

    assert {:ok, result} =
             StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert public_steps(result) == []
    refute result.tool_calls == []
  end

  test "cancellation settles pending steps without inventing tool failures" do
    events = [
      event(:tool_started, 1, %{tool_name: "search"}, tool_call_id: "a"),
      event(:request_cancelled, 2, %{})
    ]

    assert {:error, :cancelled, result} =
             StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [%{"state" => "unknown"}] = public_steps(result)
    assert ToolStep.project(result.trace) == public_steps(result)
  end

  test "legacy bare completions succeed without interpreting their arbitrary payload" do
    events = [
      event(
        :tool_completed,
        1,
        %{tool_name: "search", result: %{error: "an application field, not an error envelope"}},
        tool_call_id: "bare"
      ),
      event(:request_failed, 2, %{error: :cancelled})
    ]

    assert {:error, :cancelled, result} =
             StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [%{"state" => "succeeded"}] = public_steps(result)
  end

  test "uncorrelated legacy tool text is not suppressed by another invocation's snapshot" do
    events = [
      event(:tool_completed, 1, %{tool_name: "search", result: {:ok, "done"}},
        tool_call_id: "known"
      ),
      event(:tool_started, 2, %{tool_name: "legacy"}),
      event(:tool_completed, 3, %{tool_name: "legacy", result: "done"}),
      event(:request_completed, 4, %{result: "done"})
    ]

    assert {:ok, result} =
             StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [%{"id" => "known"}] = public_steps(result)

    refute_receive {:broadcast, :tool_call, "Using legacy", :tool_call}
    refute_receive {:broadcast, :tool_call, "Finished legacy", :tool_call}
    assert Enum.any?(result.tool_calls, &(&1["name"] == "legacy"))
  end

  test "late events without a name cannot erase an observed public name" do
    events = [
      event(:tool_started, 1, %{tool_name: "search"}, tool_call_id: "a"),
      event(:tool_started, 2, %{}, tool_call_id: "a"),
      event(:tool_completed, 3, %{result: {:ok, "done"}}, tool_call_id: "a"),
      event(:request_completed, 4, %{result: "done"})
    ]

    assert {:ok, result} =
             StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [%{"name" => "search", "label" => "search"}] = public_steps(result)
  end

  property "replayed starts and completions preserve public identity and first-observed sequence" do
    check all(repetitions <- integer(1..10)) do
      start = event(:tool_started, 1, %{tool_name: "search"}, tool_call_id: "a")

      completed =
        event(:tool_completed, 2, %{tool_name: "search", result: {:ok, "done", []}},
          tool_call_id: "a"
        )

      events =
        List.duplicate(start, repetitions) ++
          List.duplicate(completed, repetitions) ++
          [start, event(:request_completed, 3, %{result: "done"})]

      assert {:ok, result} =
               StreamEvents.consume(events, incoming(), status_module: FakeStatus)

      assert [%{"id" => "a", "sequence" => 1, "state" => "succeeded"}] = public_steps(result)
      assert ToolStep.project(result.trace) == public_steps(result)
      assert Enum.count(result.trace, &(&1["type"] == "tool_call")) == 1
    end
  end

  defp public_steps(result) do
    refute Map.has_key?(result, :tool_steps)
    ToolStep.project(result.tool_calls)
  end

  test "opted-in lifecycle starts only on native request_started and before streamed content" do
    events = [
      event(:request_started, 0, %{}),
      event(:request_started, 1, %{}),
      event(:llm_delta, 10, %{chunk_type: :content, delta: "hello"}),
      event(:request_completed, 20, %{result: "hello"})
    ]

    assert {:ok, result} =
             StreamEvents.consume(events, incoming(),
               status_module: FakeStatus,
               notify_execution_lifecycle: true
             )

    assert result.incoming.metadata.status_message_id == incoming().metadata.request_id
    assert_receive {:broadcast, :execution_started, "Preparing answer", :status}
    refute_receive {:broadcast, :answering, "hello", :stream_delta}
    assert result.answer == "hello"
    refute_received {:broadcast, :execution_started, _, _}
  end

  test "native rejection never announces an assistant start" do
    assert {:error, :busy, _} =
             StreamEvents.consume([event(:request_failed, 0, %{error: :busy})], incoming(),
               status_module: FakeStatus,
               notify_execution_lifecycle: true
             )

    refute_received {:broadcast, :execution_started, _, _}
  end

  test "coalesces small deltas into the final result without a forced terminal update" do
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
    assert result.measurements["input_tokens"] == 1
    assert result.measurements["output_tokens"] == 2
    refute Map.has_key?(result.measurements, "prompt_tokens")
    refute Map.has_key?(result.measurements, "completion_tokens")
    assert result.measurements["turn_count"] == 1
    assert result.measurements["llm_call_count"] == 1
    assert result.model == "openai:gpt-4o-mini"
    assert result.agent == %{id: 42, name: "Answering"}
    refute result.answer_published?
    refute_receive {:broadcast, :answering, "hello world", :stream_delta}
    refute_receive {:broadcast, _, _, _}
  end

  test "uses llm_completed usage when terminal usage is empty" do
    events = [
      event(:llm_completed, 20, %{
        text: "hello world",
        usage: %{input_tokens: 3, output_tokens: 1}
      }),
      event(:request_completed, 30, %{result: "hello world", usage: %{}})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert result.usage.input_tokens == 3
    assert result.usage.output_tokens == 1
    assert result.measurements["input_tokens"] == 3
    assert result.measurements["output_tokens"] == 1
    assert result.measurements["total_tokens"] == 4
  end

  property "tool-only model turns are measured once even without content deltas" do
    check all(calls <- integer(1..8), duplicates <- integer(1..3), max_runs: 40) do
      events =
        Enum.flat_map(1..calls, fn iteration ->
          id = "call-#{iteration}"

          started =
            event(:llm_started, iteration * 10, %{model: "test-model"},
              iteration: iteration,
              llm_call_id: id
            )

          completed =
            event(:llm_completed, iteration * 10 + 1, %{usage: %{}},
              iteration: iteration,
              llm_call_id: id
            )

          List.duplicate(started, duplicates) ++ [completed]
        end) ++ [event(:request_completed, 100, %{result: "Done"})]

      assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)
      assert result.measurements["turn_count"] == calls
      assert result.measurements["llm_call_count"] == calls
      assert result.measurements["tool_call_count"] == 0
    end
  end

  test "keeps per-call usage attributed to the model that produced it" do
    events = [
      event(:llm_started, 10, %{model: "openai:gpt-4o-mini"}, llm_call_id: "call-1"),
      event(
        :llm_completed,
        20,
        %{model: "openai:gpt-4o-mini", usage: %{input_tokens: 3, output_tokens: 2}},
        llm_call_id: "call-1"
      ),
      event(:llm_started, 30, %{model: "anthropic:claude-sonnet-4"}, llm_call_id: "call-2"),
      event(
        :llm_completed,
        40,
        %{model: "anthropic:claude-sonnet-4", usage: %{input_tokens: 5, output_tokens: 4}},
        llm_call_id: "call-2"
      ),
      event(:request_completed, 50, %{
        result: "done",
        usage: %{input_tokens: 8, output_tokens: 6, total_tokens: 14}
      })
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert result.usage == %{input_tokens: 8, output_tokens: 6, total_tokens: 14}

    assert result.llm_calls == [
             %{
               llm_call_id: "call-1",
               request_id: "req-1",
               run_id: "run-1",
               model: "openai:gpt-4o-mini",
               input_tokens: 3,
               output_tokens: 2,
               total_tokens: 5
             },
             %{
               llm_call_id: "call-2",
               request_id: "req-1",
               run_id: "run-1",
               model: "anthropic:claude-sonnet-4",
               input_tokens: 5,
               output_tokens: 4,
               total_tokens: 9
             }
           ]
  end

  test "deduplicates repeated logical LLM completions" do
    completion =
      event(
        :llm_completed,
        20,
        %{model: "openai:gpt-4o-mini", usage: %{input_tokens: 3, output_tokens: 2}},
        llm_call_id: "call-1"
      )

    events = [
      completion,
      %{completion | id: "retry-event", seq: 21},
      event(:request_completed, 30, %{result: "done", usage: %{}})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)
    assert result.usage == %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
    assert [%{llm_call_id: "call-1", total_tokens: 5}] = result.llm_calls
  end

  property "repeated completion delivery does not change attributed or aggregate usage" do
    check all(
            input_tokens <- integer(0..10_000),
            output_tokens <- integer(0..10_000),
            deliveries <- integer(1..5)
          ) do
      completion =
        event(
          :llm_completed,
          20,
          %{
            model: "openai:gpt-4o-mini",
            usage: %{input_tokens: input_tokens, output_tokens: output_tokens}
          },
          llm_call_id: "call-1"
        )

      events =
        List.duplicate(completion, deliveries) ++
          [event(:request_completed, 30, %{result: "done", usage: %{}})]

      assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)
      assert result.usage.input_tokens == input_tokens
      assert result.usage.output_tokens == output_tokens
      assert result.usage.total_tokens == input_tokens + output_tokens
      assert [%{llm_call_id: "call-1", total_tokens: total}] = result.llm_calls
      assert total == input_tokens + output_tokens
    end
  end

  test "uses empty usage when llm_completed carries no usage map" do
    events = [
      event(:llm_completed, 10, %{usage: nil}),
      event(:request_completed, 20, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert result.answer == "done"
    assert result.usage == %{}
  end

  test "merges numeric token usage after ignoring invalid token values" do
    events = [
      event(:llm_completed, 10, %{usage: %{"input_tokens" => "n/a"}}),
      event(:llm_completed, 20, %{usage: %{"input_tokens" => 4}}),
      event(:request_completed, 30, %{result: "done", usage: %{}})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert result.usage.input_tokens == 4
    assert result.measurements["input_tokens"] == 4
    assert is_nil(result.measurements["total_tokens"])
  end

  test "normalizes string token keys and numeric usage values" do
    events = [
      event(:llm_completed, 10, %{
        usage: %{
          "input_tokens" => "2",
          "output_tokens" => "3",
          "inputTokenCount" => "5",
          "outputTokenCount" => "7"
        }
      }),
      event(:request_completed, 20, %{result: "done", usage: %{}})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert result.usage.input_tokens == 2
    assert result.usage.output_tokens == 3
    assert result.usage.inputTokenCount == 5
    assert result.usage.outputTokenCount == 7
    assert result.measurements["input_tokens"] == 2
    assert result.measurements["output_tokens"] == 3
    assert result.measurements["total_tokens"] == 5
  end

  test "normalizes provider token usage shapes from llm_completed" do
    events = [
      event(:llm_completed, 20, %{
        usage: %{
          "tokens" => %{
            "promptTokenCount" => "8.0",
            "candidatesTokenCount" => 3.9
          },
          "totalTokenCount" => "11.0"
        }
      }),
      event(:request_completed, 30, %{result: "done", usage: %{}})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert result.measurements["input_tokens"] == 8
    assert result.measurements["output_tokens"] == 3
    assert result.measurements["total_tokens"] == 11
  end

  test "records segment changes without forcing a short text publication" do
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
    refute_receive {:broadcast, :answering, "The answer is 42.", :stream_delta}
    assert result.answer == "The answer is 42."
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

  test "json_safe converts structs without recursing forever" do
    safe = StreamEvents.json_safe(%JsonStruct{name: :ok})

    assert safe["name"] == "ok"
    assert safe["__struct__"] == Atom.to_string(JsonStruct)
    assert Jason.encode!(safe)
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
    refute_receive {:broadcast, :tool_call, "Finished search", :tool_call}
  end

  property "repeated and late tool starts preserve correlated arguments and completed evidence" do
    check all(amount <- integer(0..100), duplicate_count <- integer(1..4), max_runs: 40) do
      args = %{value: 2, amount: amount}

      started =
        event(:tool_started, 10, %{tool_name: "add", arguments: args},
          tool_call_id: "stable-tool"
        )

      blank = event(:tool_started, 11, %{tool_name: "add"}, tool_call_id: "stable-tool")

      completed =
        event(
          :tool_completed,
          20,
          %{tool_name: "add", result: %{result: 2 + amount}, duration_ms: 10},
          tool_call_id: "stable-tool"
        )

      sequences = [
        [started | List.duplicate(blank, duplicate_count)] ++ [completed],
        [completed | List.duplicate(blank, duplicate_count)] ++ [started],
        [started, completed, blank, completed]
      ]

      for sequence <- sequences do
        assert {:ok, result} =
                 StreamEvents.consume(
                   sequence ++ [event(:request_completed, 30, %{result: "done"})],
                   incoming(),
                   status_module: FakeStatus
                 )

        assert [trace] = Enum.filter(result.trace, &(&1["type"] == "tool_call"))
        assert trace["arguments"] == %{"value" => 2, "amount" => amount}
        assert trace["status"] == "completed"
        assert trace["response"] == %{"result" => 2 + amount}
        assert result.measurements["tool_call_count"] == 1
      end
    end
  end

  test "a blank repeated tool start never replaces the real arguments with a nil string" do
    events = [
      event(:tool_started, 10, %{tool_name: "add", arguments: %{value: 2, amount: 3}},
        tool_call_id: "add-once"
      ),
      event(:tool_started, 11, %{tool_name: "add"}, tool_call_id: "add-once"),
      event(:tool_completed, 20, %{tool_name: "add", result: %{result: 5}},
        tool_call_id: "add-once"
      ),
      event(:tool_started, 21, %{tool_name: "add"}, tool_call_id: "add-once"),
      event(:request_completed, 30, %{result: "5"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [
             %{
               "arguments" => %{"value" => 2, "amount" => 3},
               "response" => %{"result" => 5},
               "status" => "completed"
             }
           ] = result.trace

    assert result.measurements["tool_call_count"] == 1
  end

  test "externalizes materialized media from canonical tool results without adding bytes to trace" do
    bytes = <<0, 1, 2, 3>>

    record = %Record{
      id: "media-1",
      kind: :file,
      content: bytes,
      name: "image.png",
      mime_type: "image/png",
      size: 4,
      attributes: %{"source_type" => "communication_media"}
    }

    events = [
      event(:tool_started, 10, %{tool_name: "download_document", arguments: %{}},
        tool_call_id: "tool-media"
      ),
      event(
        :tool_completed,
        20,
        %{
          tool_name: "download_document",
          result: {:ok, %ToolResult{output: %{record: record}, content: []}, []}
        },
        tool_call_id: "tool-media"
      ),
      event(:request_completed, 30, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [artifact] = result.trace_artifacts
    assert artifact.content == bytes
    assert artifact.record["id"] == "media-1"
    refute Map.has_key?(artifact.record, "content")
    assert Jason.encode!(result.trace)
    refute inspect(result.trace) =~ inspect(bytes)
  end

  test "externalizes binary skill resource content parts without adding bytes to trace" do
    bytes = <<137, "PNG", 13, 10, 26, 10, 0, 1, 2>>

    payload = %{
      skill: "diagram-skill",
      resource_id: "resource-1",
      kind: :image,
      filename: "diagram.png",
      size: byte_size(bytes),
      mime_type: "image/png",
      __content_parts__: [ContentPart.image(bytes, "image/png")]
    }

    events = [
      event(:tool_started, 10, %{tool_name: "load_skill_resource", arguments: %{}},
        tool_call_id: "tool-skill-resource"
      ),
      event(
        :tool_completed,
        20,
        %{tool_name: "load_skill_resource", result: {:ok, payload, []}},
        tool_call_id: "tool-skill-resource"
      ),
      event(:request_completed, 30, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [artifact] = result.trace_artifacts
    assert artifact.content == bytes
    assert artifact.name == "diagram.png"
    assert artifact.mime_type == "image/png"
    assert artifact.record["skill"] == "diagram-skill"
    assert artifact.record["resource_id"] == "resource-1"

    encoded_trace = Jason.encode!(result.trace)
    refute encoded_trace =~ Base.encode64(bytes)
    refute encoded_trace =~ "__content_parts__"
  end

  test "externalizes base64 communication media from canonical tool results" do
    record = %Record{
      id: "media",
      kind: :file,
      content: "AAECAw==",
      attributes: %{source_type: "communication_media", encoding: "base64"}
    }

    events = [
      event(
        :tool_completed,
        20,
        %{
          tool_name: "download_document",
          result: {:ok, %{record: record}, []}
        },
        tool_call_id: "coverage-tool"
      ),
      event(:request_completed, 30, %{result: "done"})
    ]

    assert {:ok, result} =
             StreamEvents.consume(events, coverage_incoming(),
               status_module: FakeStatus,
               started_at: 0
             )

    assert result.answer == "done"

    assert [
             %{
               content: <<0, 1, 2, 3>>,
               size: 4,
               name: "attachment",
               mime_type: "application/octet-stream",
               tool_call_id: "coverage-tool",
               tool_name: "download_document",
               record: %{"id" => "media"} = artifact_record
             }
           ] = result.trace_artifacts

    refute Map.has_key?(artifact_record, "content")

    assert [%{"id" => "coverage-tool", "response" => ["ok", %{"record" => safe_record}, []]}] =
             result.trace

    assert safe_record["content"] == "nil"
    assert [%{"id" => "coverage-tool", "response" => response}] = result.tool_calls
    assert response == ["ok", %{"record" => safe_record}, []]
    assert Jason.encode!(result.trace)
    assert Jason.encode!(result.tool_calls)
    refute_receive {:broadcast, :tool_call, "Finished download_document", :tool_call}
  end

  test "sanitizes invalid base64 communication media without failing the request" do
    record = %Record{
      id: "media",
      kind: :file,
      content: "%%%invalid%%%",
      attributes: %{"source_type" => "communication_media", "encoding" => "base64"}
    }

    events = [
      event(
        :tool_completed,
        20,
        %{
          tool_name: "download_document",
          result: {:ok, %{"record" => record}, []}
        },
        tool_call_id: "coverage-tool"
      ),
      event(:request_completed, 30, %{result: "done"})
    ]

    assert {:ok, result} =
             StreamEvents.consume(events, coverage_incoming(),
               status_module: FakeStatus,
               started_at: 0
             )

    assert result.answer == "done"
    assert result.trace_artifacts == []
    assert [%{"response" => ["ok", %{"record" => safe_record}, []]} = trace_entry] = result.trace
    assert safe_record["id"] == "media"
    assert safe_record["content"] == "nil"
    assert [%{"response" => response}] = result.tool_calls
    assert response == ["ok", %{"record" => safe_record}, []]
    refute Jason.encode!(result.trace) =~ "%%%invalid%%%"
    refute Jason.encode!(result.tool_calls) =~ "%%%invalid%%%"
    refute_receive {:broadcast, :tool_call, "Finished download_document", :tool_call}
    assert trace_entry["id"] == "coverage-tool"
  end

  test "retains metadata for unmaterialized communication media records" do
    record = %Record{
      id: "media",
      kind: :file,
      content: nil,
      attributes: %{source_type: "communication_media", encoding: "base64"}
    }

    events = [
      event(
        :tool_completed,
        20,
        %{tool_name: "download_document", result: {:ok, %{record: record}, []}},
        tool_call_id: "coverage-tool"
      ),
      event(:request_completed, 30, %{result: "done"})
    ]

    assert {:ok, result} =
             StreamEvents.consume(events, coverage_incoming(),
               status_module: FakeStatus,
               started_at: 0
             )

    assert result.answer == "done"
    assert result.trace_artifacts == []
    assert [%{"response" => ["ok", %{"record" => safe_record}, []]}] = result.trace
    assert safe_record["id"] == "media"
    assert safe_record["content"] == "nil"
    refute_receive {:broadcast, :tool_call, "Finished download_document", :tool_call}
  end

  test "omits ignored resource content parts from tool results" do
    payload = %{
      resource_id: "resource-1",
      label: "private",
      __content_parts__: [ContentPart.text("private-resource-text")]
    }

    events = [
      event(:tool_completed, 20, %{tool_name: "download_document", result: {:ok, payload, []}},
        tool_call_id: "coverage-tool"
      ),
      event(:request_completed, 30, %{result: "done"})
    ]

    assert {:ok, result} =
             StreamEvents.consume(events, coverage_incoming(),
               status_module: FakeStatus,
               started_at: 0
             )

    assert result.answer == "done"
    assert result.trace_artifacts == []
    assert [%{"response" => ["ok", safe_payload, []]}] = result.trace
    assert safe_payload["resource_id"] == "resource-1"
    assert safe_payload["label"] == "private"
    refute Map.has_key?(safe_payload, "__content_parts__")
    encoded = Jason.encode!(result.trace) <> Jason.encode!(result.tool_calls)
    refute encoded =~ "private-resource-text"
    refute_receive {:broadcast, :tool_call, "Finished download_document", :tool_call}
  end

  property "base64 communication media round-trips into artifacts only" do
    check all(bytes <- binary(min_length: 0, max_length: 64), max_runs: 25) do
      record = %Record{
        id: "property-media",
        kind: :file,
        content: Base.encode64(bytes),
        attributes: %{source_type: "communication_media", encoding: "base64"}
      }

      events = [
        event(
          :tool_completed,
          20,
          %{tool_name: "download_document", result: {:ok, %{record: record}, []}},
          tool_call_id: "coverage-tool"
        ),
        event(:request_completed, 30, %{result: "done"})
      ]

      assert {:ok, result} =
               StreamEvents.consume(events, coverage_incoming(),
                 status_module: FakeStatus,
                 started_at: 0
               )

      assert [%{content: ^bytes, size: size}] = result.trace_artifacts
      assert size == byte_size(bytes)
      assert [%{"response" => ["ok", %{"record" => %{"content" => "nil"}}, []]}] = result.trace
    end
  end

  test "uses struct event timestamps for tool started entries" do
    events = [
      %StructEvent{
        kind: :tool_started,
        at_ms: 1_765_411_200_000,
        iteration: 0,
        tool_call_id: "struct-tool",
        data: %{tool_name: "lookup"}
      },
      event(:request_completed, 30, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [%{"id" => "struct-tool", "started_at" => started_at}] = result.tool_calls
    assert is_binary(started_at)
  end

  test "keeps tool started timestamps nil when the map has no at_ms field" do
    events = [
      %{
        kind: :tool_started,
        iteration: 0,
        tool_call_id: "map-tool",
        data: %{tool_name: "lookup"}
      },
      event(:request_completed, 20, %{result: "done"})
    ]

    assert {:ok, result} = StreamEvents.consume(events, incoming(), status_module: FakeStatus)

    assert [%{"id" => "map-tool", "started_at" => nil}] = result.tool_calls
  end

  test "keeps tool started timestamps nil when a struct has no at_ms field" do
    events = [
      %StreamEventWithoutTimestamp{
        kind: :tool_started,
        iteration: 0,
        tool_call_id: "missing-time-tool",
        tool_name: "lookup",
        data: %{tool_name: "lookup"}
      },
      event(:request_completed, 30, %{result: "done"})
    ]

    assert {:ok, result} =
             StreamEvents.consume(events, coverage_incoming(), status_module: FakeStatus)

    assert [%{"id" => "missing-time-tool", "started_at" => nil, "started_at_ms" => nil}] =
             result.tool_calls

    refute_receive {:broadcast, :tool_call, "Using lookup", :tool_call}
  end

  describe "terminal events" do
    test "returns cancelled result and registers cancellation" do
      incoming = incoming()

      events = [
        event(:llm_delta, 10, %{chunk_type: :content, delta: "partial"}),
        event(:request_cancelled, 20, %{reason: "user stopped"})
      ]

      assert {:error, :cancelled, result} =
               StreamEvents.consume(events, incoming, status_module: FakeStatus)

      assert result.answer == "partial"
      assert result.termination_reason == :cancelled
      assert [%{"type" => "content"}] = result.trace
      refute result.answer_published?
      refute_receive {:broadcast, :answering, "partial", :stream_delta}
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
    refute_receive {:broadcast, :thinking, "reason", :reasoning}
    refute_receive {:broadcast, :answering, "answer", :stream_delta}
    assert result.answer == "answer"
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

  test "json_safe falls back to inspect for bitstrings" do
    safe = StreamEvents.json_safe(<<1::1>>)

    assert is_binary(safe)
    assert String.starts_with?(safe, "<<1::size(1)>>")
    assert Jason.encode!(safe)
  end

  test "json_safe falls back to inspect when sanitized value still cannot encode" do
    safe = StreamEvents.json_safe(%{bad: <<255>>})

    assert Jason.encode!(safe)
  end

  describe "attachment selection" do
    setup do
      scope = make_ref()
      on_exit(fn -> OpaqueAliases.clear_scope(scope) end)
      %{scope: scope}
    end

    test "completion results own selection, suppress replay and stop at termination", %{
      scope: scope
    } do
      add = selection(scope, "add-a", "add", [record("a")])
      remove = selection(scope, "remove-a", "remove", [record("a")])
      b = selection(scope, "add-b", "add", [record("b")])
      foreign = %{add | request_id: "foreign", tool_call_id: "foreign"}

      assert {:ok, result} = consume([add, remove, add, foreign, b, completed(), add], scope)
      assert [%Record{id: "b"}] = result.attachments
      assert Enum.count(result.tool_calls, &(&1["name"] == "attach_documents")) == 3

      public = ToolStep.project(result.tool_calls)

      for step <- public do
        refute Map.has_key?(step, "arguments")
        refute Map.has_key?(step, "response")
        refute inspect(step) =~ "provenance"
      end

      assert {:ok, %{attachments: []}} = consume([completed()], scope)
    end

    test "failed tools do not mutate and failed or incomplete requests expose no files", %{
      scope: scope
    } do
      add = selection(scope, "add-a", "add", [record("a")])

      failed = %{
        selection(scope, "clear", "replace", [])
        | data: %{result: {:error, :unauthorized, []}}
      }

      assert {:ok, %{attachments: [%Record{id: "a"}]}} =
               consume([add, failed, completed()], scope)

      assert {:ok, %{attachments: []}} = consume([add], scope)

      for kind <- [:request_failed, :request_cancelled] do
        assert {:error, _, %{attachments: []}} =
                 consume([add, %{kind: kind, request_id: "r", data: %{error: :failed}}], scope)
      end
    end

    test "missing, foreign and retired alias scopes fail closed", %{scope: scope} do
      event = selection(scope, "add-a", "add", [record("a")])

      for wrong_scope <- [nil, make_ref()] do
        assert {:ok,
                %{
                  answer: "Done",
                  attachment_error: :invalid_attachment_selection,
                  attachments: []
                }} =
                 consume([event, completed()], wrong_scope)
      end

      OpaqueAliases.clear_scope(scope)

      assert {:ok,
              %{answer: "Done", attachment_error: :invalid_attachment_selection, attachments: []}} =
               consume([event, completed()], scope)
    end

    test "malformed successful instructions reject the whole batch", %{scope: scope} do
      valid = selection(scope, "add-a", "add", [record("a")])

      for output <- [
            "invalid",
            %{operation: "delete", records: []},
            %{operation: "add", records: [%{"id" => "unsigned"}]},
            %{operation: "replace", records: "invalid"}
          ] do
        invalid = %{valid | tool_call_id: "invalid", data: %{result: {:ok, output, []}}}

        assert {:ok,
                %{
                  answer: "Done",
                  attachment_error: :invalid_attachment_selection,
                  attachments: []
                }} =
                 consume([valid, invalid, completed()], scope)
      end
    end

    test "structured tool results retain validated selection without exposing it in public steps",
         %{scope: scope} do
      event = selection(scope, "structured", "add", [record("structured-record")])
      {:ok, output, []} = event.data.result
      event = %{event | data: %{result: {:ok, %ReqLLM.ToolResult{output: output}, []}}}

      assert {:ok, result} = consume([event, completed()], scope)
      assert [%Record{id: "structured-record"}] = result.attachments
      refute inspect(ToolStep.project(result.tool_calls)) =~ "structured-record"
    end
  end

  defp selection(scope, id, operation, records) do
    assert {:ok, {:ok, output, []}} =
             Factory.after_tool_call(
               %{action_module: AttachDocuments},
               {:ok, %{operation: operation, records: records}, []},
               %{opaque_alias_scope: scope}
             )

    %{
      kind: :tool_completed,
      request_id: "r",
      tool_call_id: id,
      tool_name: "attach_documents",
      data: %{result: {:ok, output, []}}
    }
  end

  defp consume(events, scope) do
    StreamEvents.consume(
      Stream.filter(events, &(&1.request_id == "r")),
      %Incoming{content: "select", channel_id: "c", provider: :web, message_id: "r"},
      opaque_alias_scope: scope,
      request: %{id: "r"},
      status_module: Zaq.TestSupport.NoopAgentStatus
    )
  end

  defp completed, do: %{kind: :request_completed, request_id: "r", data: %{result: "Done"}}

  defp record(id) do
    {:ok, record} = Provenance.seal(%Record{id: id, kind: :file})
    record
  end

  defp incoming do
    %Incoming{
      content: "question",
      channel_id: "chan-1",
      provider: :web,
      metadata: %{request_id: "req-1", session_id: "sess-1"}
    }
  end

  defp coverage_incoming do
    %{incoming() | metadata: %{request_id: nil, session_id: "coverage"}, message_id: nil}
  end

  defp event(kind, at_ms, data, attrs \\ []) do
    %{
      id: "evt-#{at_ms}",
      seq: at_ms,
      at_ms: at_ms,
      run_id: "run-1",
      request_id: "req-1",
      iteration: Keyword.get(attrs, :iteration, 0),
      kind: kind,
      llm_call_id: Keyword.get(attrs, :llm_call_id, "llm-1"),
      tool_call_id: Keyword.get(attrs, :tool_call_id),
      tool_name: Map.get(data, :tool_name),
      data: data
    }
  end
end
