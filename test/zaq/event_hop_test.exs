defmodule Zaq.EventHopTest do
  use ExUnit.Case, async: true

  alias Zaq.EventHop

  test "new/3 builds a hop" do
    now = DateTime.utc_now()
    hop = EventHop.new(:agent, :sync, now)

    assert hop.destination == :agent
    assert hop.type == :sync
    assert hop.timestamp == now
  end
end
