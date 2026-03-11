defmodule Zaq.PeerConnectorTest do
  use ExUnit.Case, async: true

  alias Zaq.PeerConnector

  @topic "node:events"

  setup do
    Phoenix.PubSub.subscribe(Zaq.PubSub, @topic)
    :ok
  end

  describe "handle_info/2 nodeup" do
    test "broadcasts {:node_up, node} on nodeup" do
      peer = :ai@localhost

      {:noreply, _state} = PeerConnector.handle_info({:nodeup, peer}, initial_state())

      assert_receive {:node_up, ^peer}, 500
    end

    test "broadcasts node_up for any node" do
      peer = :unknown@localhost

      {:noreply, _state} = PeerConnector.handle_info({:nodeup, peer}, initial_state())

      assert_receive {:node_up, ^peer}, 500
    end

    test "returns noreply with updated state" do
      state = initial_state()

      assert {:noreply, _new_state} = PeerConnector.handle_info({:nodeup, :ai@localhost}, state)
    end
  end

  describe "lifecycle" do
    test "init/1 enables monitoring and returns empty state" do
      assert {:ok, %{}} = PeerConnector.init([])
    end

    test "named process is registered" do
      pid = Process.whereis(PeerConnector)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "handle_info/2 nodedown" do
    test "broadcasts {:node_down, node} on nodedown" do
      peer = :ai@localhost

      {:noreply, _state} = PeerConnector.handle_info({:nodedown, peer}, initial_state())

      assert_receive {:node_down, ^peer}, 500
    end

    test "returns noreply with updated state" do
      state = initial_state()

      assert {:noreply, _new_state} = PeerConnector.handle_info({:nodedown, :ai@localhost}, state)
    end
  end

  describe "handle_info/2 unknown messages" do
    test "ignores unknown messages without crashing" do
      state = initial_state()

      assert {:noreply, ^state} = PeerConnector.handle_info(:unexpected, state)
    end

    test "ignores unknown messages of any shape" do
      state = initial_state()

      assert {:noreply, ^state} = PeerConnector.handle_info({:something, :else}, state)
    end
  end

  # -- Helpers --

  defp initial_state, do: %{peers: [], remaining: []}
end
