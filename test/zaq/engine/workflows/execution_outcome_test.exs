defmodule Zaq.Engine.Workflows.ExecutionOutcomeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Action.Error
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.ExecutionOutcome
  alias Zaq.Engine.Workflows.PendingApproval
  alias Zaq.Engine.Workflows.StepApproval
  alias Zaq.Engine.Workflows.Steps.MapCollect
  alias Zaq.Engine.Workflows.Test.ExecutionProbe

  @opts [timeout: 0, max_retries: 0, backoff: 0, telemetry: :silent]

  defp pending do
    %PendingApproval{run_id: "run", step_name: "review[2]", approval_token: "token"}
  end

  test "typed success control survives real inner and outer Jido validation" do
    control = pending()
    outcome = {:ok, %{}, workflow_control: control}
    assert ^outcome = Jido.Exec.run(ExecutionProbe, %{}, %{outer: true, outcome: outcome}, @opts)
    assert {:pending, ^control, %{}} = ExecutionOutcome.classify(outcome)
  end

  test "output validation failure retains metadata but never suspends" do
    outcome = {:ok, %{value: 42}, workflow_control: pending()}
    result = Jido.Exec.run(ExecutionProbe, %{}, %{outer: true, outcome: outcome}, @opts)
    assert {:error, error, workflow_control: %PendingApproval{}} = result
    assert {:error, ^error, %{}} = ExecutionOutcome.classify(result)
    assert Error.to_map(error).type == :validation_error
  end

  test "scalar output rejection remains a structured Jido failure" do
    result = Jido.Exec.run(ExecutionProbe, %{}, %{outcome: {:ok, 42}}, @opts)
    assert {:error, error, %{}} = ExecutionOutcome.classify(result)
    # The installed keyword-schema validator raises BadMapError for scalar output;
    # Exec normalizes it as an execution error, without accepting or wrapping 42.
    assert %{details: %{original_exception: %BadMapError{term: 42}}} = error

    assert %{type: :execution_error, details: %{original_exception: %{term: 42}}} =
             ExecutionOutcome.error_details(error)
  end

  test "domain data and untyped metadata are never control" do
    control = pending()
    data = %{workflow_control: control}
    assert {:ok, ^data, %{}} = ExecutionOutcome.classify({:ok, data})
    assert {:ok, ^control, %{}} = ExecutionOutcome.classify({:ok, control})

    assert {:ok, %{}, %{}} =
             ExecutionOutcome.classify({:ok, %{}, workflow_control: Map.from_struct(control)})
  end

  test "pending control cannot hide business output" do
    assert {:error, error, %{}} =
             ExecutionOutcome.classify({:ok, %{value: "data"}, workflow_control: pending()})

    assert Error.to_map(error).type == :validation_error
  end

  test "malformed result and metadata fail deliberately" do
    for result <- [:ok, {:ok, %{}, [:invalid]}, {:ok, %{}, nil}] do
      assert {:error, error, %{}} = ExecutionOutcome.classify(result)
      assert Error.to_map(error).type == :validation_error
    end
  end

  test "durable association requires exact run, step, token and pending status" do
    control = pending()

    approval = %StepApproval{
      workflow_run_id: "run",
      step_name: "review[2]",
      approval_token: "token",
      status: "pending"
    }

    assert :ok = PendingApproval.validate(control, "run", "review[2]", approval)

    for invalid <- [
          nil,
          %{approval | status: "approved"},
          %{approval | approval_token: "other"},
          %{approval | workflow_run_id: "other"},
          %{approval | step_name: "review[1]"}
        ] do
      assert {:error, _} = PendingApproval.validate(control, "run", "review[2]", invalid)
    end

    assert {:error, _} = PendingApproval.validate(control, "other", "review[2]", approval)
    assert {:error, _} = PendingApproval.validate(control, "run", "review[1]", approval)

    assert {:error, _} =
             PendingApproval.validate(
               %{control | approval_token: nil},
               "run",
               "review[2]",
               approval
             )
  end

  test "success and error triples retain broader metadata while consuming control" do
    logs = [%{message: "attempt"}]
    metadata = [logs: logs, source: "provider", workflow_control: pending()]

    assert {:error, :failure, %{logs: ^logs, source: "provider"}} =
             ExecutionOutcome.classify({:error, :failure, metadata})

    assert {:ok, %{value: "ok"}, %{logs: ^logs, source: "provider"}} =
             ExecutionOutcome.classify(
               {:ok, %{value: "ok"}, Keyword.delete(metadata, :workflow_control)}
             )
  end

  test "returned and raised conditions classify by exception identity, not prose" do
    condition = %ConditionNotMet{field: "age", op: "gt", actual: 10, expected: 20}

    for context <- [%{outcome: {:error, condition}}, %{raise: condition}] do
      result = Jido.Exec.run(ExecutionProbe, %{}, context, @opts)
      assert {:skipped, ^condition, %{}} = ExecutionOutcome.classify(result)
    end

    error = Error.execution_error("Condition not met: age")
    assert {:error, ^error, %{}} = ExecutionOutcome.classify({:error, error})
  end

  test "normalized errors retain type, message, details and retryability" do
    error = Error.execution_error("provider unavailable", %{code: 503, retry: false})

    assert %{
             type: :execution_error,
             message: "provider unavailable",
             details: %{code: 503},
             retryable?: false
           } =
             ExecutionOutcome.error_details(error)
  end

  test "internal empty-schema MapCollect remains executable through Jido" do
    assert {:ok, %{"results" => [], "errors" => [], "count" => 0}} =
             Jido.Exec.run(MapCollect, %{input: []}, %{}, @opts)
  end

  property "arbitrary business maps cannot request suspension" do
    check all(data <- map_of(string(:alphanumeric), integer(), max_length: 8), max_runs: 40) do
      assert {:ok, ^data, %{}} = ExecutionOutcome.classify({:ok, data})
      assert {:ok, ^data, %{}} = ExecutionOutcome.classify({:ok, data, workflow_control: data})
    end
  end
end
