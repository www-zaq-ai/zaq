defmodule Zaq.Agent.Tools.PipelineRunnerTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.PipelineRunner

  defmodule StepA do
    def run(params, _ctx), do: {:ok, Map.put(params, :a, true)}
  end

  defmodule StepB do
    def run(params, _ctx), do: {:ok, Map.put(params, :b, true), logs: [%{event: "ok"}]}
  end

  describe "run_pipeline/4" do
    test "invokes on_step callback with step indexes" do
      parent = self()
      pipeline = [{StepA, %{}}, {StepB, %{}}]

      on_step = fn idx -> send(parent, {:step_idx, idx}) end

      assert {:ok, %{seed: 1, a: true, b: true}} =
               PipelineRunner.run_pipeline(%{seed: 1}, pipeline, %{}, on_step)

      assert_received {:step_idx, 0}
      assert_received {:step_idx, 1}
    end

    test "supports default on_step argument (3-arity call)" do
      pipeline = [{StepA, %{}}, {StepB, %{}}]

      assert {:ok, %{seed: 1, a: true, b: true}} =
               PipelineRunner.run_pipeline(%{seed: 1}, pipeline, %{})
    end
  end

  describe "handle_step_result/1" do
    test "continues when step returns {:ok, result, logs}" do
      assert {:cont, {:ok, %{x: 1}}} =
               PipelineRunner.handle_step_result({:ok, %{x: 1}, [%{event: "ok"}]})
    end
  end
end
