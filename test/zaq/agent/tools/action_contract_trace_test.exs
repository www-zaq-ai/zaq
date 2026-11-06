defmodule Zaq.Agent.Tools.ActionContractTraceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Agent.StateOp.SetState
  alias Jido.AI.Observe
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolResult

  alias Zaq.Agent.Tools.ActionContract
  alias Zaq.Contracts.Record
  alias Zaq.TestSupport.NestedActionProbe

  defmodule ResultAction do
    use Jido.Action,
      name: "trace_result",
      description: "Returns a supplied result",
      schema: [result: [type: :any, required: true]]

    def run(%{result: result}, _context), do: result
  end

  defmodule ThrowingAction do
    def schema, do: throw(:original_throw)
    def name, do: "throwing_trace"
    def validate_params(params), do: {:ok, params}
    def run(_, _), do: throw(:original_throw)
  end

  defmodule RetryAction do
    use Jido.Action,
      name: "trace_retry",
      description: "Retries using an explicitly owned counter",
      schema: []

    def run(_, %{attempts: attempts, test_pid: owner} = context) do
      send(owner, {:attempt, context.tool_call_id})
      attempt = Agent.get_and_update(attempts, fn n -> {n, n + 1} end)
      if attempt == 0, do: {:error, :temporary_failure}, else: {:ok, %{value: 42}}
    end
  end

  defmodule BlockingAction do
    use Jido.Action,
      name: "trace_blocking",
      description: "Blocks until timeout",
      schema: []

    def run(_, _context) do
      receive do
        :release -> {:ok, %{}}
      end
    end
  end

  defp context do
    owner = self()

    %{
      tool_call_id: "native.root.é",
      on_tool_event: fn event ->
        send(owner, {:trace, event})
        :ok
      end
    }
  end

  test "children inherit their path and callback without changing the caller" do
    context = context()
    assert {:ok, %{value: 42}} = ActionContract.execute(NestedActionProbe, %{depth: 1}, context)
    assert_receive {:trace, start}
    assert_receive {:trace, child_start}
    assert_receive {:trace, child_done}
    assert_receive {:trace, done}
    assert start.kind == :tool_started
    assert done.kind == :tool_completed
    assert done.tool_call_id == start.tool_call_id
    assert done.id != start.id

    assert start.data.invocation_path == [
             context.tool_call_id,
             List.last(start.data.invocation_path)
           ]

    assert child_start.data.invocation_path ==
             start.data.invocation_path ++ [List.last(child_start.data.invocation_path)]

    assert child_start.data.parent_id == start.tool_call_id
    assert child_done.data.outcome == "succeeded"
    assert done.data.duration_ms >= 0
    assert context.tool_call_id == "native.root.é"
    refute Map.has_key?(context, :tool_invocation_path)
  end

  property "opaque roots round-trip and independent sibling invocations never collide" do
    check all(root <- string(:utf8, min_length: 1, max_length: 40), max_runs: 30) do
      context = %{context() | tool_call_id: root}
      for _ <- 1..2, do: ActionContract.execute(ResultAction, %{result: {:ok, %{}}}, context)
      assert_receive {:trace, first}
      assert_receive {:trace, _}
      assert_receive {:trace, second}
      assert_receive {:trace, _}
      ["zaq", encoded, segment] = String.split(first.tool_call_id, ".")
      assert Base.url_decode64!(encoded, padding: false) == root
      assert {:ok, ^segment} = Ecto.UUID.cast(segment)
      assert first.tool_call_id != second.tool_call_id
      assert first.data.parent_id == root
    end
  end

  test "original error/success envelopes and effects are not replaced by trace evidence" do
    for result <- [{:ok, %{password: "private"}}, {:error, :failure}, {:ok, %{value: 1}, []}] do
      expected = ActionContract.execute(ResultAction, %{result: result})
      assert ActionContract.execute(ResultAction, %{result: result}, context()) == expected
      assert_receive {:trace, _}
      assert_receive {:trace, done}
      assert done.data.outcome == if(elem(result, 0) == :ok, do: "succeeded", else: "failed")
      refute inspect(done.data.result) =~ "private"
    end
  end

  test "metadata callbacks redact tagged payloads, effects, structs and runtime values" do
    record = %Record{
      id: "record",
      kind: :document,
      name: "example",
      content: "RAW_RESOURCE_BYTES"
    }

    result = {:ok, %{record: record, api_key: "PRIVATE_KEY", runtime: fn -> :ok end}, []}
    assert ActionContract.execute(ResultAction, %{result: result}, context()) == result
    assert_receive {:trace, started}
    assert_receive {:trace, done}
    encoded = done.data.result |> Observe.sanitize_transport_payload() |> Jason.encode!()
    refute encoded =~ "PRIVATE_KEY"
    refute encoded =~ "RAW_RESOURCE_BYTES"
    refute encoded =~ "#Function"
    refute inspect(started.data.arguments) =~ "PRIVATE_KEY"
  end

  test "nonempty Jido effects remain exact caller values without exposing runtime effect internals" do
    effect = %SetState{attrs: %{secret: "private-effect-value"}}
    result = {:ok, %{value: 42}, [effect]}
    assert ActionContract.execute(ResultAction, %{result: result}, context()) == result
    assert_receive {:trace, _}
    assert_receive {:trace, done}
    refute inspect(done.data.result) =~ "private-effect-value"
    assert done.data.outcome == "succeeded"
  end

  test "normalization failures still have one failed span" do
    missing = __MODULE__.Missing

    assert {:error, {:invalid_action, ^missing, _}} =
             ActionContract.execute(missing, %{}, context())

    assert_receive {:trace, started}
    assert_receive {:trace, completed}
    assert started.tool_call_id == completed.tool_call_id
    assert completed.data.outcome == "failed"
  end

  test "callback failures and invalid destinations do not affect execution" do
    for callback <- [
          fn _ -> raise "callback" end,
          fn _ -> throw(:callback) end,
          fn _ -> exit(:callback) end,
          fn _ -> {:error, :callback} end,
          :invalid
        ] do
      context = %{context() | on_tool_event: callback}
      assert {:ok, %{value: 42}} = ActionContract.execute(NestedActionProbe, %{depth: 0}, context)
    end

    assert {:ok, %{value: 42}} = ActionContract.execute(NestedActionProbe, %{depth: 0})
  end

  test "escaping normalization throws retain their kind and value after failed evidence" do
    assert catch_throw(ActionContract.execute(ThrowingAction, %{}, context())) == :original_throw
    assert_receive {:trace, _}
    assert_receive {:trace, %{data: %{outcome: "failed"}}}
  end

  test "Jido retries keep one span and one identity, while timeout remains a failed result" do
    attempts = start_supervised!({Agent, fn -> 0 end})
    ctx = Map.merge(context(), %{attempts: attempts, test_pid: self()})

    assert {:ok, %{value: 42}} =
             ActionContract.execute(RetryAction, %{}, ctx, max_retries: 1, backoff: 0)

    assert_receive {:trace, started}
    assert_receive {:trace, done}
    assert_receive {:attempt, first_id}
    assert_receive {:attempt, ^first_id}
    assert first_id == started.tool_call_id
    assert done.data.outcome == "succeeded"
    refute_received {:trace, _}

    assert {:error, _} =
             ActionContract.execute(BlockingAction, %{}, context(), timeout: 20, max_retries: 0)

    assert_receive {:trace, _}
    assert_receive {:trace, %{data: %{outcome: "failed"}}}
  end

  test "default callback uses native request envelopes and a custom callback overrides it" do
    sink_context = %{
      tool_call_id: "root",
      request_id: "request",
      run_id: "run",
      tool_event_sink: {:pid, self()}
    }

    assert {:ok, %{value: 42}} =
             ActionContract.execute(NestedActionProbe, %{depth: 0}, sink_context)

    assert_receive {:jido_ai_request_event,
                    %{kind: :tool_started, request_id: "request", run_id: "run"}}

    assert_receive {:jido_ai_request_event, %{kind: :tool_completed}}

    assert {:ok, %{value: 42}} =
             ActionContract.execute(
               NestedActionProbe,
               %{depth: 0},
               Map.merge(sink_context, context())
             )

    assert_receive {:trace, _}
    assert_receive {:trace, _}
    refute_received {:jido_ai_request_event, _}
  end

  test "malformed invocation paths execute without trace or caller mutation" do
    for path <- [[], ["other"], ["root", "not-a-uuid"], ["root" | 42]] do
      supplied = Map.merge(context(), %{tool_call_id: "root", tool_invocation_path: path})
      original = supplied

      assert {:ok, %{value: 42}} =
               ActionContract.execute(ResultAction, %{result: {:ok, %{value: 42}}}, supplied)

      assert supplied == original
      refute_received {:trace, _}
    end
  end

  test "missing trace destination does not create a span" do
    assert {:ok, %{value: 42}} =
             ActionContract.execute(ResultAction, %{result: {:ok, %{value: 42}}}, %{
               tool_call_id: "root"
             })

    refute_received {:trace, _}
    refute_received {:jido_ai_request_event, _}

    assert {:ok, %{value: 42}} =
             ActionContract.execute(ResultAction, %{result: {:ok, %{value: 42}}}, %{
               tool_call_id: "root",
               on_tool_event: nil
             })

    refute_received {:trace, _}
    refute_received {:jido_ai_request_event, _}
  end

  test "deep evidence is bounded without truncating the Action result" do
    nested = Enum.reduce(1..20, :deepest_marker, fn _, value -> [value] end)
    result = {:ok, %{deep: nested}}
    assert ActionContract.execute(ResultAction, %{result: result}, context()) == result
    assert_receive {:trace, %{kind: :tool_started}}
    assert_receive {:trace, %{kind: :tool_completed, data: %{outcome: "succeeded"}} = completed}
    assert inspect(completed.data.result) =~ "[omitted]"
    refute inspect(completed.data.result) =~ "deepest_marker"
  end

  test "typed media evidence differs by destination, never by returned value" do
    record = %Record{
      id: "media-evidence",
      kind: :document,
      name: "distinctive",
      content: "RECORD_BYTES",
      materialization_handle: "HANDLE_SENTINEL",
      provenance_ref: "PROVENANCE_SENTINEL"
    }

    part = ContentPart.image("PART_BYTES", "image/png")

    tool_result = %ToolResult{
      output: %{record: record, __content_parts__: [part]},
      content: [part]
    }

    result = {:ok, tool_result}

    assert ActionContract.execute(ResultAction, %{result: result}, context()) == result
    assert_receive {:trace, %{kind: :tool_started} = custom_started}
    assert_receive {:trace, %{kind: :tool_completed} = custom_done}
    refute inspect(custom_started.data.arguments) =~ "PART_BYTES"
    refute inspect(custom_started.data.arguments) =~ "RECORD_BYTES"
    assert {:ok, custom_evidence, []} = custom_done.data.result
    assert is_map(custom_evidence)
    assert custom_evidence.content == nil
    custom_record = custom_evidence.output.record
    assert is_map(custom_record)
    assert custom_record.content == nil
    assert custom_record.materialization_handle == "[REDACTED]"
    assert custom_record.provenance_ref == "[REDACTED]"
    [custom_part] = custom_evidence.output.__content_parts__
    assert is_map(custom_part)
    refute Map.has_key?(custom_part, :data)
    refute Map.has_key?(custom_part, :url)

    sink_context = %{
      tool_call_id: "root",
      request_id: "request",
      run_id: "run",
      tool_event_sink: {:pid, self()}
    }

    assert ActionContract.execute(ResultAction, %{result: result}, sink_context) == result
    assert_receive {:jido_ai_request_event, %{kind: :tool_started} = native_started}
    assert inspect(native_started) |> String.contains?("PART_BYTES") == false
    assert inspect(native_started) |> String.contains?("RECORD_BYTES") == false
    assert_receive {:jido_ai_request_event, %{kind: :tool_completed} = native_done}
    assert {:ok, %ToolResult{content: nil} = native_evidence, []} = native_done.data.result

    assert %Record{
             content: "RECORD_BYTES",
             materialization_handle: "[REDACTED]",
             provenance_ref: "[REDACTED]"
           } = native_evidence.output.record

    assert [%ContentPart{data: "PART_BYTES"}] = native_evidence.output.__content_parts__
  end

  test "unusual envelopes retain Jido's actual result" do
    for result <- [{:error, :failure, []}, :unclassified] do
      untraced = ActionContract.execute(ResultAction, %{result: result})
      traced = ActionContract.execute(ResultAction, %{result: result}, context())
      assert traced == untraced
      assert_receive {:trace, _}
      assert_receive {:trace, completed}

      case traced do
        {:error, _} -> assert completed.data.outcome == "failed"
        {:error, _, _} -> assert completed.data.outcome == "failed"
        {:ok, _} -> assert completed.data.outcome == "succeeded"
        {:ok, _, _} -> assert completed.data.outcome == "succeeded"
        other -> assert completed.data.outcome == "unknown" and completed.data.result == other
      end
    end
  end
end
