defmodule Zaq.Agent.Tools.Workflow.SleepTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.Sleep
  alias Zaq.Engine.Workflows.Action

  @ctx %{}

  test "satisfies the workflow action contract" do
    assert :ok = Action.validate(Sleep)
  end

  test "delegates to Jido's built-in sleep action" do
    assert {:ok, %{duration_ms: 1}} = Sleep.run(%{duration_ms: 1}, @ctx)
  end

  test "returns the duration that was slept" do
    assert {:ok, %{duration_ms: 5}} = Sleep.run(%{duration_ms: 5}, @ctx)
  end
end
