defmodule Zaq.Agent.Tools.Workflow.ConditionContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Action.Error
  alias Zaq.Agent.Tools.Workflow.Condition

  @opts [timeout: 0, max_retries: 0, backoff: 0, telemetry: :silent]

  test "missing input and invalid enum values fail before action execution" do
    for params <- [%{}, %{input: %{}, on_fail: "bogus"}, %{input: %{}, on_fail: nil}] do
      assert {:error, error} = Jido.Exec.run(Condition, params, %{}, @opts)
      assert Error.to_map(error).type == :validation_error
      refute Error.retryable?(error)
    end
  end

  test "JSON aliases normalize before validation and conflicting aliases are rejected" do
    assert {:ok, %{passed: true, input: %{}}} =
             Jido.Exec.run(Condition, %{"input" => %{}, "on_fail" => "halt"}, %{}, @opts)

    assert {:error, error} =
             Jido.Exec.run(Condition, %{"input" => %{}, input: %{other: true}}, %{}, @opts)

    refute Error.retryable?(error)
    assert Error.to_map(error).message =~ "Conflicting"
  end

  test "references must resolve to a map" do
    context = %{__cascade__: %{start: %{value: 42}}}

    assert {:ok, %{passed: true, input: %{value: 42}}} =
             Jido.Exec.run(Condition, %{input: "start"}, context, @opts)

    for reference <- ["missing", "start.value"] do
      assert {:error, error} = Jido.Exec.run(Condition, %{input: reference}, context, @opts)
      assert Error.to_map(error).type == :validation_error
      refute Error.retryable?(error)
    end
  end

  test "deterministic halt is non-retryable while continue returns routing data" do
    params = %{input: %{active: false}, conditions: [%{"key" => "active", "value" => true}]}
    assert {:error, error} = Jido.Exec.run(Condition, params, %{}, @opts)

    assert Error.to_map(error).message ==
             "Condition not met: active must equal true but was false"

    refute Error.retryable?(error)

    assert {:ok, %{passed: false, failed_conditions: [_]} = result} =
             Jido.Exec.run(Condition, Map.put(params, :on_fail, "continue"), %{}, @opts)

    refute Map.has_key?(result, :input)
  end

  property "normalization is idempotent and unknown enum strings are rejected" do
    check all(value <- string(:alphanumeric, max_length: 15), max_runs: 40) do
      params = %{"input" => %{}, "on_fail" => value}
      assert {:ok, normalized} = Condition.on_before_validate_params(params)
      assert {:ok, ^normalized} = Condition.on_before_validate_params(normalized)

      if value not in ["halt", "continue"] do
        assert {:error, error} = Jido.Exec.run(Condition, params, %{}, @opts)
        refute Error.retryable?(error)
      end
    end
  end
end
