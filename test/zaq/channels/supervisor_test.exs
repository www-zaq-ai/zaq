defmodule Zaq.Channels.SupervisorTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Supervisor

  test "init/1 supervises pending questions agent" do
    assert {:ok, {spec, children}} = Supervisor.init([])

    assert spec.strategy == :one_for_one
    assert Enum.map(children, & &1.id) == [Zaq.Channels.PendingQuestions]
  end
end
