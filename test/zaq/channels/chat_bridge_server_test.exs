defmodule Zaq.Channels.ChatBridgeServerTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.ChatBridgeServer

  test "starts and initializes with empty adapters" do
    {:ok, pid} = GenServer.start_link(ChatBridgeServer, adapters: %{})
    assert is_pid(pid)
    GenServer.stop(pid)
  end

  test "handle_event returns error for unknown adapter" do
    {:ok, pid} = GenServer.start_link(ChatBridgeServer, adapters: %{})
    result = ChatBridgeServer.handle_event(pid, :unknown_adapter, %{})
    assert {:error, _} = result
    GenServer.stop(pid)
  end
end
