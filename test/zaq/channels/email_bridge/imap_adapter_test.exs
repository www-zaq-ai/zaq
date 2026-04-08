defmodule Zaq.Channels.EmailBridge.ImapAdapterTest do
  use ExUnit.Case, async: true

  alias Mailroom.IMAP
  alias Zaq.Channels.EmailBridge.ImapAdapter
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.FakeImapServer

  def sink(_config, _payload, _opts), do: :ok

  test "to_internal/2 delegates parsing with mailbox from connection details" do
    payload = %{
      "body_text" => "hello",
      "from" => %{"address" => "alice@example.com", "name" => "Alice"},
      "message_id" => "<msg-1@example.com>"
    }

    assert %Incoming{} =
             incoming =
             ImapAdapter.to_internal(payload, %{
               "mailbox" => "INBOX"
             })

    assert incoming.channel_id == "alice@example.com"
    assert incoming.provider == :"email:imap"
    assert incoming.metadata["email"]["mailbox"] == "INBOX"
  end

  test "to_internal/2 reads mailbox from atom key too" do
    payload = %{"body_text" => "hello", "from" => %{"address" => "alice@example.com"}}

    assert %Incoming{} = incoming = ImapAdapter.to_internal(payload, %{mailbox: "Support"})
    assert incoming.metadata["email"]["mailbox"] == "Support"
  end

  test "connect/2 returns invalid_imap_url when url is missing" do
    assert {:error, :invalid_imap_url} = ImapAdapter.connect(%{}, "INBOX")
  end

  test "connect/2 and list_mailboxes/1 work against fake IMAP server" do
    fake = start_supervised!({FakeImapServer, owner: self(), mailboxes: ["INBOX", "Support"]})
    config = FakeImapServer.config(fake)

    assert {:ok, ["INBOX", "Support"]} = ImapAdapter.list_mailboxes(config)
    assert {:ok, client} = ImapAdapter.connect(config, "INBOX")

    assert_receive {:imap_fake_command, ^fake, :login, _}, 1_000
    assert_receive {:imap_fake_command, ^fake, :list, _}, 1_000
    assert_receive {:imap_fake_command, ^fake, :select, _}, 1_000

    assert :ok = ImapAdapter.disconnect(client)
    assert_receive {:imap_fake_command, ^fake, :logout, _}, 1_000
  end

  test "connect/2 accepts URL without scheme and uses token as password" do
    fake = start_supervised!({FakeImapServer, owner: self()})
    %{port: port} = FakeImapServer.endpoint(fake)

    config = %{
      url: "127.0.0.1:#{port}",
      username: "demo",
      token: "token-secret",
      ssl: false,
      timeout: "1500",
      ssl_depth: "4"
    }

    assert {:ok, client} = ImapAdapter.connect(config, "INBOX")
    assert_receive {:imap_fake_command, ^fake, :login, raw_login}, 1_000
    assert raw_login =~ "token-secret"
    assert :ok = ImapAdapter.disconnect(client)
  end

  test "list_mailboxes/1 returns invalid_imap_url when url is missing" do
    assert {:error, :invalid_imap_url} = ImapAdapter.list_mailboxes(%{})
  end

  test "connect/list_mailboxes return connection error when endpoint is unreachable" do
    config = %{
      url: "imap://127.0.0.1:1",
      username: "demo",
      password: "secret",
      ssl: false,
      timeout: 75
    }

    assert {:error, _} = ImapAdapter.connect(config, "INBOX")
    assert {:error, _} = ImapAdapter.list_mailboxes(config)
  end

  test "connect/2 handles different timeout, port and ssl_depth value shapes" do
    base = %{url: "imap://127.0.0.1", username: "demo", password: "secret", ssl: false}

    assert {:error, _} =
             ImapAdapter.connect(
               Map.merge(base, %{port: 143, timeout: 100, ssl_depth: 0}),
               "INBOX"
             )

    assert {:error, _} =
             ImapAdapter.connect(
               Map.merge(base, %{port: "143", timeout: "100", ssl_depth: "1"}),
               "INBOX"
             )

    assert {:error, _} =
             ImapAdapter.connect(
               Map.merge(base, %{port: "bad", timeout: "bad", ssl_depth: "bad"}),
               "INBOX"
             )
  end

  test "connect/2 handles SSL handshake failure against plain TCP endpoint" do
    fake = start_supervised!({FakeImapServer, owner: self()})
    %{port: port} = FakeImapServer.endpoint(fake)

    config = %{
      url: "imap://127.0.0.1:#{port}",
      username: "demo",
      password: "secret",
      ssl: true,
      timeout: 500
    }

    assert {:error, _} = ImapAdapter.connect(config, "INBOX")
  end

  test "connect/2 returns invalid_imap_url when url is not binary" do
    config = %{url: 123, username: "demo", password: "secret", ssl: false}
    assert {:error, :invalid_imap_url} = ImapAdapter.connect(config, "INBOX")
  end

  test "fetch_unseen maps payload, mark_as_read updates flags, disconnect logs out" do
    fake =
      start_supervised!(
        {FakeImapServer,
         owner: self(),
         message: %{
           subject: "Need help",
           from_name: "Bob",
           from_mailbox: "bob",
           from_host: "example.com",
           message_id: "<msg-555@example.com>",
           in_reply_to: "<thread-1@example.com>",
           references: "<thread-1@example.com>",
           rfc822: "RAW-EMAIL"
         }}
      )

    config = FakeImapServer.config(fake)
    assert {:ok, client} = ImapAdapter.connect(config, "INBOX")

    assert :ok =
             ImapAdapter.fetch_unseen(client, "INBOX", fn payload ->
               send(self(), {:seen_payload, payload})
             end)

    assert_receive {:seen_payload, payload}, 1_000
    assert payload["mailbox"] == "INBOX"
    assert payload["seq"] == 1
    assert payload["uid"] == 101
    assert payload["subject"] == "Need help"
    assert payload["from"] == %{name: "bob", address: "bob@example.com"}
    assert payload["message_id"] == "<msg-555@example.com>"
    assert payload["in_reply_to"] == "<thread-1@example.com>"
    assert payload["references"] == "<thread-1@example.com>"
    assert payload["raw_rfc822"] == "RAW-EMAIL"

    assert :ok = ImapAdapter.mark_as_read(client, payload["seq"])
    assert FakeImapServer.seen?(fake)

    assert :ok = ImapAdapter.disconnect(client)
    assert_receive {:imap_fake_command, ^fake, :store, _}, 1_000
    assert_receive {:imap_fake_command, ^fake, :logout, _}, 1_000
  end

  test "fetch_unseen handles missing envelope and header fields" do
    fake =
      start_supervised!(
        {FakeImapServer, owner: self(), include_envelope: false, include_header: false}
      )

    config = FakeImapServer.config(fake)
    assert {:ok, client} = ImapAdapter.connect(config, "INBOX")

    assert :ok =
             ImapAdapter.fetch_unseen(client, "INBOX", fn payload ->
               send(self(), {:minimal_payload, payload})
             end)

    assert_receive {:minimal_payload, payload}, 1_000
    assert payload["subject"] == nil
    assert payload["from"] == %{name: nil, address: nil}
    assert payload["in_reply_to"] == nil
    assert payload["references"] == nil

    assert :ok = ImapAdapter.disconnect(client)
  end

  test "enter_idle/2 accepts timeout from config map and integer" do
    fake = start_supervised!({FakeImapServer, owner: self()})
    config = FakeImapServer.config(fake)
    assert {:ok, client} = ImapAdapter.connect(config, "INBOX")

    assert :ok = ImapAdapter.enter_idle(client, %{idle_timeout: "45000"})
    client_state = :sys.get_state(client)
    assert is_reference(client_state.idle_timer)
    assert is_integer(Process.read_timer(client_state.idle_timer))

    _ = IMAP.cancel_idle(client)

    assert :ok = ImapAdapter.enter_idle(client, 35_000)
    client_state = :sys.get_state(client)
    assert is_reference(client_state.idle_timer)
    assert is_integer(Process.read_timer(client_state.idle_timer))

    assert :ok = ImapAdapter.disconnect(client)
  end

  test "fetch_unseen/3 returns tagged error when callback raises" do
    fake = start_supervised!({FakeImapServer, owner: self()})
    config = FakeImapServer.config(fake)
    assert {:ok, client} = ImapAdapter.connect(config, "INBOX")

    assert {:error, {:imap_fetch_failed, _}} =
             ImapAdapter.fetch_unseen(client, "INBOX", fn _payload ->
               raise "callback boom"
             end)

    assert :ok = ImapAdapter.disconnect(client)
  end

  test "listener_child_specs/2 reads selected mailboxes from nested settings" do
    config = %{
      provider: "email:imap",
      settings: %{
        "imap" => %{
          "selected_mailboxes" => [" INBOX ", "Support", "", "Support"],
          "poll_interval" => "45000",
          "mark_as_read" => false,
          "load_initial_unread" => true,
          "idle_timeout" => "123456"
        }
      }
    }

    assert {:ok, specs} =
             ImapAdapter.listener_child_specs("email:imap_99",
               config: config,
               sink_mfa: {__MODULE__, :sink, []},
               sink_opts: [bridge_id: "email:imap_99"]
             )

    assert length(specs) == 3

    [inbox_spec | _] = specs
    {_, _, [listener_opts]} = inbox_spec.start

    assert listener_opts[:mailbox] == "INBOX"
    assert listener_opts[:retry_interval] == 45_000
    assert listener_opts[:mark_as_read] == false
    assert listener_opts[:load_initial_unread] == true
    assert listener_opts[:idle_timeout] == 123_456
    assert listener_opts[:sink_mfa] == {__MODULE__, :sink, []}
  end

  test "listener_child_specs/2 prefers top-level selected_mailboxes over nested settings" do
    config = %{
      provider: "email:imap",
      selected_mailboxes: ["Sales"],
      settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
    }

    assert {:ok, [spec]} =
             ImapAdapter.listener_child_specs("email:imap_77",
               config: config,
               sink_mfa: {__MODULE__, :sink, []},
               sink_opts: []
             )

    {_, _, [listener_opts]} = spec.start
    assert listener_opts[:mailbox] == "Sales"
  end

  test "runtime_specs/3 returns listener specs including adapter in sink options" do
    config = %{
      provider: "email:imap",
      selected_mailboxes: ["INBOX"]
    }

    assert {:ok, {state_spec, [listener_spec]}} =
             ImapAdapter.runtime_specs(config, "email:imap_55",
               sink_mfa: {__MODULE__, :sink, []},
               sink_opts: [bridge_id: "email:imap_55"]
             )

    assert state_spec == nil
    {_, _, [listener_opts]} = listener_spec.start
    assert listener_opts[:sink_opts][:adapter] == ImapAdapter
  end

  test "listener_child_specs/2 returns missing_listener_options without required opts" do
    assert {:error, :missing_listener_options} =
             ImapAdapter.listener_child_specs("email:imap_404", sink_opts: [])
  end

  test "listener_child_specs/2 falls back for invalid poll and idle values" do
    config = %{
      provider: "email:imap",
      selected_mailboxes: ["INBOX", " ", :bad],
      poll_interval: "nope",
      mark_as_read: nil,
      load_initial_unread: "true",
      idle_timeout: "invalid"
    }

    assert {:ok, [spec]} =
             ImapAdapter.listener_child_specs("email:imap_500",
               config: config,
               sink_mfa: {__MODULE__, :sink, []},
               sink_opts: []
             )

    {_, _, [listener_opts]} = spec.start
    assert listener_opts[:mailbox] == "INBOX"
    assert listener_opts[:retry_interval] == 30_000
    assert listener_opts[:idle_timeout] == 1_500_000
    assert listener_opts[:mark_as_read] == true
    assert listener_opts[:load_initial_unread] == false
  end

  test "listener_child_specs/2 reads atom-key IMAP settings" do
    config = %{
      settings: %{
        imap: %{
          selected_mailboxes: ["INBOX"],
          poll_interval: 12_345,
          mark_as_read: false,
          load_initial_unread: true,
          idle_timeout: 654_321
        }
      }
    }

    assert {:ok, [spec]} =
             ImapAdapter.listener_child_specs("email:imap_atom_settings",
               config: config,
               sink_mfa: {__MODULE__, :sink, []},
               sink_opts: []
             )

    {_, _, [listener_opts]} = spec.start
    assert listener_opts[:mailbox] == "INBOX"
    assert listener_opts[:retry_interval] == 12_345
    assert listener_opts[:mark_as_read] == false
    assert listener_opts[:load_initial_unread] == true
    assert listener_opts[:idle_timeout] == 654_321
  end

  test "listener_child_specs/2 raises when config is not a map" do
    assert_raise FunctionClauseError, fn ->
      ImapAdapter.listener_child_specs("email:imap_non_map",
        config: :invalid,
        sink_mfa: {__MODULE__, :sink, []},
        sink_opts: []
      )
    end
  end
end
