defmodule Zaq.Agent.Tools.Workflow.SleepTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.Sleep

  @ctx %{}

  test "sleeps for the given duration and returns slept_ms" do
    assert {:ok, %{slept_ms: 1}} = Sleep.run(%{duration_ms: 1}, @ctx)
  end

  test "returns the duration that was slept" do
    assert {:ok, %{slept_ms: 5}} = Sleep.run(%{duration_ms: 5}, @ctx)
  end
end
