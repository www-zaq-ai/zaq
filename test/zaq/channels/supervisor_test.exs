defmodule Zaq.Channels.SupervisorTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Supervisor

  test "init/1 starts ChatBridgeServer as the only child" do
    assert {:ok, {spec, children}} = Supervisor.init([])

    assert spec.strategy == :one_for_one
    assert [%{id: Zaq.Channels.ChatBridgeServer}] = children
  end
end
