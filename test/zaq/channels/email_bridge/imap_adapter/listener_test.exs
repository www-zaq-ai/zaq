defmodule Zaq.Channels.EmailBridge.ImapAdapter.ListenerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Zaq.Channels.EmailBridge.ImapAdapter.Listener
  alias Zaq.TestSupport.FakeImapServer

  test "init/1 reads defaults from config" do
    opts = [
      config: %{
        "poll_interval" => "42000",
        "mark_as_read" => false,
        "load_initial_unread" => true,
        "idle_timeout" => "1300000"
      },
      bridge_id: "email:imap_1",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []}
    ]

    assert {:ok, state} = Listener.init(opts)
    assert_received :connect

    assert state.retry_interval == 42_000
    assert state.mark_as_read == false
    assert state.load_initial_unread == true
    assert state.idle_timeout == 1_300_000
    assert state.client == nil
  end

  test "init/1 lets explicit options override config-derived values" do
    opts = [
      config: %{
        "poll_interval" => "42000",
        "mark_as_read" => false,
        "load_initial_unread" => false,
        "idle_timeout" => "1300000"
      },
      bridge_id: "email:imap_2",
      mailbox: "Support",
      sink_mfa: {__MODULE__, :sink, []},
      retry_interval: 9_000,
      mark_as_read: true,
      load_initial_unread: true,
      idle_timeout: 777_000
    ]

    assert {:ok, state} = Listener.init(opts)
    assert_received :connect

    assert state.retry_interval == 9_000
    assert state.mark_as_read == true
    assert state.load_initial_unread == true
    assert state.idle_timeout == 777_000
  end

  test "init/1 falls back to defaults for invalid config values" do
    opts = [
      config: %{"poll_interval" => "oops", "idle_timeout" => "bad", "mark_as_read" => nil},
      bridge_id: "email:imap_defaults",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []}
    ]

    assert {:ok, state} = Listener.init(opts)
    assert state.retry_interval == 30_000
    assert state.idle_timeout == 1_500_000
    assert state.mark_as_read == true
    assert state.load_initial_unread == false
  end

  test "init/1 reads atom-key config values" do
    opts = [
      config: %{
        poll_interval: 12_000,
        mark_as_read: false,
        load_initial_unread: true,
        idle_timeout: 9_999
      },
      bridge_id: "email:imap_atom",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []}
    ]

    assert {:ok, state} = Listener.init(opts)
    assert state.retry_interval == 12_000
    assert state.mark_as_read == false
    assert state.load_initial_unread == true
    assert state.idle_timeout == 9_999
  end

  test "init/1 uses defaults when config is not a map" do
    opts = [
      config: :invalid,
      bridge_id: "email:imap_non_map",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []}
    ]

    assert {:ok, state} = Listener.init(opts)
    assert state.retry_interval == 30_000
    assert state.mark_as_read == true
    assert state.load_initial_unread == false
    assert state.idle_timeout == 1_500_000
  end

  test "handle_info/2 keeps state on idle_notify when client is nil" do
    state = %{
      config: %{},
      bridge_id: "email:imap_3",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []},
      sink_opts: [],
      client: nil,
      retry_interval: 30_000,
      mark_as_read: true,
      load_initial_unread: false,
      idle_timeout: 1_500_000
    }

    assert {:noreply, ^state} = Listener.handle_info(:idle_notify, state)
  end

  test "handle_info/2 idle_notify clears stale dead client and schedules reconnect" do
    dead_client = spawn(fn -> :ok end)
    ref = Process.monitor(dead_client)
    assert_receive {:DOWN, ^ref, :process, ^dead_client, _reason}

    state = %{
      config: %{},
      bridge_id: "email:imap_stale_client",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []},
      sink_opts: [],
      client: dead_client,
      retry_interval: 5,
      mark_as_read: true,
      load_initial_unread: false,
      idle_timeout: 1_500_000
    }

    log =
      capture_log(fn ->
        assert {:noreply, updated} = Listener.handle_info(:idle_notify, state)
        assert updated.client == nil
      end)

    assert_receive :reconnect, 50
    assert log =~ "fetch unseen failed" or log =~ "IMAP client exited"
  end

  test "handle_info/2 connect keeps client nil when connection fails" do
    state = %{
      config: %{url: "imap://127.0.0.1:1", username: "demo", password: "secret", ssl: false},
      bridge_id: "email:imap_connect_fail",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []},
      sink_opts: [],
      client: nil,
      retry_interval: 30,
      mark_as_read: true,
      load_initial_unread: false,
      idle_timeout: 1_500_000
    }

    log =
      capture_log(fn ->
        assert {:noreply, updated} = Listener.handle_info(:connect, state)
        assert updated.client == nil
      end)

    assert log =~ "connect failed"
  end

  test "handle_info/2 connect establishes client when connection succeeds" do
    fake = start_supervised!({FakeImapServer, owner: self()})

    state = %{
      config: FakeImapServer.config(fake),
      bridge_id: "email:imap_connect_ok",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []},
      sink_opts: [],
      client: nil,
      retry_interval: 30,
      mark_as_read: true,
      load_initial_unread: false,
      idle_timeout: 60_000
    }

    assert {:noreply, updated} = Listener.handle_info(:connect, state)
    assert is_pid(updated.client)
    assert_receive {:imap_fake_command, ^fake, :login, _}, 1_000
    # Stop the unsupervised IMAP client before FakeImapServer teardown to avoid
    # a Mailroom.IMAP crash on {:tcp_closed} when the fake server's socket closes.
    capture_log(fn -> GenServer.stop(updated.client, :normal) end)
  end

  test "handle_info/2 reconnect path reuses connect_and_idle" do
    state = %{
      config: %{url: "imap://127.0.0.1:1", username: "demo", password: "secret", ssl: false},
      bridge_id: "email:imap_reconnect_fail",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []},
      sink_opts: [],
      client: nil,
      retry_interval: 30,
      mark_as_read: true,
      load_initial_unread: false,
      idle_timeout: 1_500_000
    }

    log =
      capture_log(fn ->
        assert {:noreply, updated} = Listener.handle_info(:reconnect, state)
        assert updated.client == nil
      end)

    assert log =~ "connect failed"
  end

  test "handle_info/2 reconnect establishes client when server is reachable" do
    fake = start_supervised!({FakeImapServer, owner: self()})

    state = %{
      config: FakeImapServer.config(fake),
      bridge_id: "email:imap_reconnect_ok",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []},
      sink_opts: [],
      client: nil,
      retry_interval: 30,
      mark_as_read: true,
      load_initial_unread: false,
      idle_timeout: 60_000
    }

    assert {:noreply, updated} = Listener.handle_info(:reconnect, state)
    assert is_pid(updated.client)
    assert_receive {:imap_fake_command, ^fake, :login, _}, 1_000
    capture_log(fn -> GenServer.stop(updated.client, :normal) end)
  end

  test "listener connects and processes idle notifications through IMAP IDLE" do
    fake = start_supervised!({FakeImapServer, owner: self()})

    listener =
      start_supervised!(
        {Listener,
         [
           config: FakeImapServer.config(fake),
           bridge_id: "email:imap_11",
           mailbox: "INBOX",
           sink_mfa: {__MODULE__, :sink, []},
           sink_opts: [test_pid: self()],
           idle_timeout: 60_000,
           retry_interval: 100,
           mark_as_read: true,
           load_initial_unread: false
         ]}
      )

    assert_receive {:imap_fake_command, ^fake, :login, _}, 1_000
    assert_receive {:imap_fake_command, ^fake, :select, _}, 1_000
    assert_receive {:imap_fake_command, ^fake, :idle, _}, 1_000

    assert :ok = FakeImapServer.trigger_exists(fake)

    assert_receive {:sink_called, payload, opts}, 1_500
    assert payload["mailbox"] == "INBOX"
    assert payload["seq"] == 1
    assert payload["subject"] == "Support request"
    assert opts[:mailbox] == "INBOX"

    assert_receive {:imap_fake_command, ^fake, :fetch, _}, 1_500
    assert_receive {:imap_fake_command, ^fake, :store, _}, 1_500
    assert_receive {:imap_fake_command, ^fake, :idle, _}, 1_500

    state = :sys.get_state(listener)
    client_pid = state.client
    assert is_pid(client_pid)
    stop_listener_and_imap_client(listener, client_pid)
  end

  test "listener does not mark messages as read when mark_as_read is false" do
    fake = start_supervised!({FakeImapServer, owner: self()})

    listener =
      start_supervised!(
        {Listener,
         [
           config: FakeImapServer.config(fake),
           bridge_id: "email:imap_12",
           mailbox: "INBOX",
           sink_mfa: {__MODULE__, :sink, []},
           sink_opts: [test_pid: self()],
           idle_timeout: 60_000,
           retry_interval: 100,
           mark_as_read: false,
           load_initial_unread: true
         ]}
      )

    assert_receive {:sink_called, payload, _opts}, 1_500
    assert payload["seq"] == 1
    refute_receive {:imap_fake_command, ^fake, :store, _}, 400
    client_pid = :sys.get_state(listener).client
    stop_listener_and_imap_client(listener, client_pid)
  end

  test "listener reconnects when IMAP client exits" do
    fake = start_supervised!({FakeImapServer, owner: self()})

    listener =
      start_supervised!(
        {Listener,
         [
           config: FakeImapServer.config(fake),
           bridge_id: "email:imap_13",
           mailbox: "INBOX",
           sink_mfa: {__MODULE__, :sink, []},
           sink_opts: [test_pid: self()],
           idle_timeout: 60_000,
           retry_interval: 50,
           mark_as_read: true,
           load_initial_unread: false
         ]}
      )

    log =
      capture_log(fn ->
        assert_receive {:imap_fake_command, ^fake, :login, _}, 1_000

        first_client = :sys.get_state(listener).client
        assert is_pid(first_client)

        Process.exit(first_client, :kill)

        assert_receive {:imap_fake_command, ^fake, :login, _}, 1_500

        second_client = :sys.get_state(listener).client
        assert is_pid(second_client)
        refute second_client == first_client
        stop_listener_and_imap_client(listener, second_client)
      end)

    assert log =~ "IMAP client exited"
  end

  defmodule SinkRaise do
    def dispatch(_config, _payload, _opts), do: raise("sink exploded")
  end

  test "sink dispatch errors are rescued and do not crash listener" do
    fake = start_supervised!({FakeImapServer, owner: self()})

    listener =
      start_supervised!(
        {Listener,
         [
           config: FakeImapServer.config(fake),
           bridge_id: "email:imap_15",
           mailbox: "INBOX",
           sink_mfa: {SinkRaise, :dispatch, []},
           sink_opts: [],
           idle_timeout: 60_000,
           retry_interval: 100,
           mark_as_read: false,
           load_initial_unread: false
         ]}
      )

    log =
      capture_log(fn ->
        assert_receive {:imap_fake_command, ^fake, :login, _}, 1_000
        assert_receive {:imap_fake_command, ^fake, :select, _}, 1_000
        assert_receive {:imap_fake_command, ^fake, :idle, _}, 1_000
        assert :ok = FakeImapServer.trigger_exists(fake)
        assert_receive {:imap_fake_command, ^fake, :fetch, _}, 1_500
        client_pid = :sys.get_state(listener).client
        stop_listener_and_imap_client(listener, client_pid)
      end)

    assert log =~ "sink dispatch failed"
  end

  test "listener terminate/2 disconnects IMAP client" do
    fake = start_supervised!({FakeImapServer, owner: self()})

    listener =
      start_supervised!(
        {Listener,
         [
           config: FakeImapServer.config(fake),
           bridge_id: "email:imap_14",
           mailbox: "INBOX",
           sink_mfa: {__MODULE__, :sink, []},
           sink_opts: [test_pid: self()],
           idle_timeout: 60_000,
           retry_interval: 100,
           mark_as_read: true,
           load_initial_unread: false
         ]}
      )

    assert_receive {:imap_fake_command, ^fake, :login, _}, 1_000
    client_pid = :sys.get_state(listener).client
    ref = Process.monitor(client_pid)
    GenServer.stop(listener, :normal)
    assert_receive {:imap_fake_command, ^fake, :logout, _}, 1_000

    receive do
      {:DOWN, ^ref, :process, ^client_pid, _} -> :ok
    after
      500 ->
        if Process.alive?(client_pid), do: GenServer.stop(client_pid, :shutdown)
        assert_receive {:DOWN, ^ref, :process, ^client_pid, _}, 1_000
    end
  end

  test "handle_info/2 clears client on monitored process exit" do
    client = self()

    state = %{
      config: %{},
      bridge_id: "email:imap_4",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []},
      sink_opts: [],
      client: client,
      retry_interval: 30_000,
      mark_as_read: true,
      load_initial_unread: false,
      idle_timeout: 1_500_000
    }

    log =
      capture_log(fn ->
        assert {:noreply, updated} = Listener.handle_info({:EXIT, client, :boom}, state)
        assert updated.client == nil
      end)

    assert log =~ "IMAP client exited"
  end

  test "handle_info/2 ignores unknown messages" do
    state = %{
      config: %{},
      bridge_id: "email:imap_5",
      mailbox: "INBOX",
      sink_mfa: {__MODULE__, :sink, []},
      sink_opts: [],
      client: nil,
      retry_interval: 30_000,
      mark_as_read: true,
      load_initial_unread: false,
      idle_timeout: 1_500_000
    }

    assert {:noreply, ^state} = Listener.handle_info(:unexpected, state)
  end

  test "terminate/2 returns :ok when there is no client" do
    assert :ok = Listener.terminate(:normal, %{})
  end

  defp stop_listener_and_imap_client(listener, client_pid) do
    ref = Process.monitor(client_pid)
    GenServer.stop(listener, :normal)

    receive do
      {:DOWN, ^ref, :process, ^client_pid, _} -> :ok
    after
      500 ->
        if Process.alive?(client_pid), do: GenServer.stop(client_pid, :shutdown)
        assert_receive {:DOWN, ^ref, :process, ^client_pid, _}, 1_000
    end
  end

  def sink(_config, payload, opts) do
    if pid = opts[:test_pid], do: send(pid, {:sink_called, payload, opts})
    :ok
  end
end
