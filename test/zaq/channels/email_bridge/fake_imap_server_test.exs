defmodule Zaq.TestSupport.FakeImapServerTest do
  use ExUnit.Case, async: true

  alias Zaq.TestSupport.FakeImapServer

  for notify? <- [false, true] do
    test "DONE completes IDLE with notification=#{notify?}" do
      fake = start_supervised!({FakeImapServer, []})
      socket = connect(fake)

      try do
        assert :ok = :gen_tcp.send(socket, "A001 IDLE\r\n")
        assert {:ok, "+ idling\r\n"} = :gen_tcp.recv(socket, 0, 1_000)

        if unquote(notify?) do
          assert :ok = FakeImapServer.trigger_exists(fake)
          assert {:ok, "* 2 EXISTS\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
        end

        assert :ok = :gen_tcp.send(socket, "DONE\r\n")
        assert {:ok, "A001 OK IDLE terminated\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
        assert :ok = :gen_tcp.send(socket, "A002 IDLE\r\n")
        assert {:ok, "+ idling\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
      after
        :gen_tcp.close(socket)
      end
    end
  end

  for shutdown <- [:normal, :supervised] do
    test "#{shutdown} shutdown closes every accepted socket and the acceptor" do
      fake = start_supervised!(Supervisor.child_spec({FakeImapServer, []}, restart: :temporary))
      sockets = for _ <- 1..3, do: connect(fake)
      state = :sys.get_state(fake)
      assert MapSet.size(state.connections) == 3
      pids = [state.acceptor | MapSet.to_list(state.connections)]
      refs = Enum.map(pids, &{&1, Process.monitor(&1)})

      try do
        case unquote(shutdown) do
          :normal -> GenServer.stop(fake, :normal)
          :supervised -> stop_supervised!(FakeImapServer)
        end

        for {pid, ref} <- refs do
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
        end

        for socket <- sockets do
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
        end
      after
        Enum.each(sockets, &:gen_tcp.close/1)
        # Also contain the original broken fake when this regression fails.
        Enum.each(pids, &Process.exit(&1, :kill))
      end
    end
  end

  defp connect(fake) do
    %{host: host, port: port} = FakeImapServer.endpoint(fake)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, packet: :line, active: false])

    assert {:ok, "* OK " <> _} = :gen_tcp.recv(socket, 0, 1_000)
    socket
  end
end
