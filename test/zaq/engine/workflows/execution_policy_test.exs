defmodule Zaq.Engine.Workflows.ExecutionPolicyTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Error
  alias Zaq.Engine.Workflows.ExecutionPolicy
  alias Zaq.Engine.Workflows.Test.AttemptProbe

  setup do
    counter = start_supervised!({Agent, fn -> 0 end})
    %{counter: counter, owner: self()}
  end

  test "outer execution never adds timeout, retry or telemetry attempts" do
    assert ExecutionPolicy.outer_options() ==
             [timeout: 0, max_retries: 0, backoff: 0, telemetry: :silent]

    assert :ok = ExecutionPolicy.validate_context(%{})
    assert {:error, error} = ExecutionPolicy.validate_context(%{__jido_deadline_ms__: 123})
    refute Error.retryable?(error)
  end

  test "timeouts are explicit non-negative integers and retries mean three total attempts" do
    for timeout <- [nil, 0, 10] do
      assert {:ok, opts} = ExecutionPolicy.inner_options(timeout, "retry")
      assert opts == [timeout: timeout || 0, max_retries: 2, backoff: 0, telemetry: :full]
    end

    for invalid <- [-1, "10", 1.5, :infinity] do
      assert {:error, error} = ExecutionPolicy.inner_options(invalid, "retry")
      refute Error.retryable?(error)
    end
  end

  test "Jido owns the attempt count and stops on a non-retryable failure", context do
    {:ok, opts} = ExecutionPolicy.inner_options(nil, "retry")

    assert {:ok, %{attempt: 3}} =
             Jido.Exec.run(AttemptProbe, %{}, Map.put(context, :mode, :transient), opts)

    Agent.update(context.counter, fn _ -> 0 end)

    assert {:error, _} =
             Jido.Exec.run(AttemptProbe, %{}, Map.put(context, :mode, :deterministic), opts)

    assert Agent.get(context.counter, & &1) == 1
  end

  test "without retry strategy a transient failure gets one attempt", context do
    {:ok, opts} = ExecutionPolicy.inner_options(nil, "skip_and_continue")

    assert {:error, _} =
             Jido.Exec.run(AttemptProbe, %{}, Map.put(context, :mode, :transient), opts)

    assert Agent.get(context.counter, & &1) == 1
  end

  test "timed attempts are killed before Jido returns", context do
    {:ok, opts} = ExecutionPolicy.inner_options(30, "retry")

    assert {:error, error} =
             Jido.Exec.run(AttemptProbe, %{}, Map.put(context, :mode, :timeout), opts)

    assert Error.to_map(error).type == :timeout

    for attempt <- 1..3 do
      assert_receive {:attempt_started, pid, ^attempt}
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    end

    assert Agent.get(context.counter, & &1) == 3
  end
end
