defmodule Zaq.Channels.MessageCorrelationTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.MessageCorrelation

  test "put/get/delete correlation entries" do
    assert :ok = MessageCorrelation.put(:web, "req-1", "msg-1")
    assert {:ok, "msg-1"} = MessageCorrelation.get(:web, "req-1")
    assert :ok = MessageCorrelation.delete(:web, "req-1")
    assert :error = MessageCorrelation.get(:web, "req-1")
  end
end
