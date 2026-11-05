defmodule Zaq.Agent.Tools.ActionContractTraceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Agent.StateOp.SetState
  alias Jido.AI.Observe

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
end
