defmodule Zaq.Channels.SupervisorTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Supervisor

  test "init/1 starts with no children — PendingQuestions is managed by the licensed feature" do
    assert {:ok, {spec, children}} = Supervisor.init([])

    assert spec.strategy == :one_for_one
    assert children == []
  end
end
