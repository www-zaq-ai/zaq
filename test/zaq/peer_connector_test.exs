defmodule Zaq.PeerConnectorTest do
  use ExUnit.Case, async: true

  alias Zaq.PeerConnector

  @topic "node:events"

  setup do
    Phoenix.PubSub.subscribe(Zaq.PubSub, @topic)
    :ok
  end

  describe "lifecycle" do
    test "init/1 monitors nodes and connects discovered peers" do
      parent = self()

      opts =
        test_opts(parent,
          host_fun: fn -> ~c"localhost" end,
          self_node_fun: fn -> :self@localhost end,
          epmd_names_fun: fn host ->
            send(parent, {:epmd_names, host})

            {:ok,
             [
               {~c"self", 1111},
               {~c"peer_true", 2222},
               {~c"peer_false", 3333},
               {~c"peer_ignored", 4444}
             ]}
          end,
          node_connect_fun: fn peer ->
            send(parent, {:connect_attempt, peer})

            case peer do
              :peer_true@localhost -> true
              :peer_false@localhost -> false
              :peer_ignored@localhost -> :ignored
            end
          end
        )

      assert {:ok, %{deps: _deps} = _state} = PeerConnector.init(opts)

      assert_receive {:monitor_nodes, true}
      assert_receive {:epmd_names, ~c"localhost"}
      assert_receive {:connect_attempt, :peer_true@localhost}
      assert_receive {:connect_attempt, :peer_false@localhost}
      assert_receive {:connect_attempt, :peer_ignored@localhost}
      refute_receive {:connect_attempt, :self@localhost}
    end

    test "init/1 handles epmd lookup errors" do
      parent = self()
      opts = test_opts(parent, epmd_names_fun: fn _host -> {:error, :nxdomain} end)

      assert {:ok, %{deps: _deps}} = PeerConnector.init(opts)

      assert_receive {:monitor_nodes, true}
      assert_receive {:log_debug, message}
      assert message =~ "EPMD query failed"
    end
  end

  describe "handle_info/2 nodeup" do
    test "broadcasts node_up and reconnects peers" do
      parent = self()
      opts = test_opts(parent, epmd_names_fun: fn _host -> {:ok, []} end)
      {:ok, state} = PeerConnector.init(opts)

      assert {:noreply, ^state} = PeerConnector.handle_info({:nodeup, :ai@localhost}, state)

      assert_receive {:broadcast, Zaq.PubSub, @topic, {:node_up, :ai@localhost}}
      assert_receive {:log_info, nodeup_message}
      assert nodeup_message =~ "Node up"
    end
  end

  describe "handle_info/2 nodedown" do
    test "broadcasts node_down and returns noreply" do
      parent = self()
      opts = test_opts(parent, epmd_names_fun: fn _host -> {:ok, []} end)
      {:ok, state} = PeerConnector.init(opts)

      assert {:noreply, ^state} = PeerConnector.handle_info({:nodedown, :ai@localhost}, state)

      assert_receive {:broadcast, Zaq.PubSub, @topic, {:node_down, :ai@localhost}}
      assert_receive {:log_warning, nodedown_message}
      assert nodedown_message =~ "Node down"
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

  defp test_opts(parent, overrides) do
    defaults = [
      monitor_nodes_fun: fn flag ->
        send(parent, {:monitor_nodes, flag})
        :ok
      end,
      epmd_names_fun: fn host ->
        send(parent, {:epmd_names, host})
        {:ok, []}
      end,
      self_node_fun: fn -> :self@localhost end,
      node_connect_fun: fn peer ->
        send(parent, {:connect_attempt, peer})
        true
      end,
      pubsub_broadcast_fun: fn pubsub, topic, msg ->
        send(parent, {:broadcast, pubsub, topic, msg})
        :ok
      end,
      host_fun: fn -> ~c"localhost" end,
      log_info_fun: fn message ->
        send(parent, {:log_info, message})
        :ok
      end,
      log_warning_fun: fn message ->
        send(parent, {:log_warning, message})
        :ok
      end,
      log_debug_fun: fn message ->
        send(parent, {:log_debug, message})
        :ok
      end
    ]

    Keyword.merge(defaults, overrides)
  end
end
