defmodule Zaq.Channels.EmailBridge.ImapAdapterTest do
  use ExUnit.Case, async: false
  use ExUnitProperties
  import ExUnit.CaptureLog
  import Mox

  alias Mailroom.IMAP
  alias Zaq.Channels.EmailBridge.ImapAdapter
  alias Zaq.Channels.EmailBridge.ImapClientMock
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.FakeImapServer

  setup :verify_on_exit!

  defp use_imap_mock(context) do
    previous = Zaq.Config.get(:zaq, :imap_client, nil)
    Application.put_env(:zaq, :imap_client, ImapClientMock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:zaq, :imap_client, previous),
        else: Application.delete_env(:zaq, :imap_client)
    end)

    context
  end

  defmodule ScriptedImapClient do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def enqueue(pid, operation, reply), do: GenServer.call(pid, {:enqueue, operation, reply})

    for operation <- [:status, :state, :fetch, :search] do
      def unquote(operation)(pid, args \\ []) do
        GenServer.call(pid, {unquote(operation), args})
      end
    end

    @impl true
    def init(opts), do: {:ok, %{replies: Keyword.get(opts, :replies, %{})}}

    @impl true
    def handle_call({:enqueue, operation, reply}, _from, state) do
      replies = Map.update(state.replies, operation, [reply], &(&1 ++ [reply]))
      {:reply, :ok, %{state | replies: replies}}
    end

    def handle_call({operation, _args}, _from, state) do
      case Map.get(state.replies, operation, []) do
        [reply | rest] ->
          reply_or_exit(reply)
          |> then(&{:reply, &1, %{state | replies: Map.put(state.replies, operation, rest)}})

        [] ->
          {:reply, {:error, :no_scripted_reply}, state}
      end
    end

    defp reply_or_exit({:exit, reason}), do: exit(reason)
    defp reply_or_exit({:raise, exception}), do: raise(exception)
    defp reply_or_exit(reply), do: reply
  end

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

  test "list_mailboxes/1 returns invalid_imap_url when url is missing" do
    assert {:error, :invalid_imap_url} = ImapAdapter.list_mailboxes(%{})
  end

  test "list_mailboxes/1 handles bare list response" do
    fake =
      start_supervised!(
        {FakeImapServer,
         owner: self(), mailboxes: ["INBOX", "Support"], list_mode: :untagged_bare_list}
      )

    config = FakeImapServer.config(fake)

    assert {:ok, ["INBOX", "Support"]} = ImapAdapter.list_mailboxes(config)
    assert_receive {:imap_fake_command, ^fake, :list, _}, 1_000
  end

  test "list_mailboxes/1 returns tagged failure for non-list LIST response" do
    fake = start_supervised!({FakeImapServer, owner: self(), list_mode: :no})

    config = FakeImapServer.config(fake)

    assert {:error, {:list_mailboxes_failed, other}} = ImapAdapter.list_mailboxes(config)
    assert match?({:error, _}, other)
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

  test "connect/list_mailboxes return invalid_imap_url when config is not a map" do
    assert {:error, :invalid_imap_url} = ImapAdapter.connect(:invalid, "INBOX")
    assert {:error, :invalid_imap_url} = ImapAdapter.list_mailboxes(:invalid)
  end

  test "connect/2 falls back to the default port when url omits one" do
    fake = start_supervised!({FakeImapServer, owner: self()})

    config =
      FakeImapServer.config(fake)
      |> Map.put(:url, "imap://127.0.0.1")

    assert {:error, _} = ImapAdapter.connect(config, "INBOX")
  end

  test "connect/2 handles ssl_depth string parsing and fallback" do
    base = %{url: "imap://127.0.0.1:1", username: "demo", password: "secret", ssl: true}

    capture_log(fn ->
      assert {:error, _} = ImapAdapter.connect(Map.put(base, :ssl_depth, "0"), "INBOX")
      assert {:error, _} = ImapAdapter.connect(Map.put(base, :ssl_depth, "bad"), "INBOX")
      assert {:error, _} = ImapAdapter.connect(base, "INBOX")
    end)
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

  test "scripted collaborator queues status, state, fetch and search replies" do
    client =
      start_supervised!(
        {ScriptedImapClient,
         replies: %{status: [1], state: [:selected], fetch: [[]], search: [[]]}}
      )

    assert :ok = ScriptedImapClient.enqueue(client, :status, 2)
    assert 1 == ScriptedImapClient.status(client)
    assert 2 == ScriptedImapClient.status(client)
    assert :selected == ScriptedImapClient.state(client)
    assert [] == ScriptedImapClient.fetch(client)
    assert [] == ScriptedImapClient.search(client)
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
           rfc822: "RAW-EMAIL",
           body_sections: %{"1" => "plain body", "2" => "<p>html body</p>"}
         },
         header: "References: <thread-1@example.com>"}
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
    assert payload["raw_header"] =~ "References: <thread-1@example.com>"
    assert payload["uid_validity"] == 1_193_810_872
    assert payload["body_text"] == "plain body"
    assert payload["body_html"] == "<p>html body</p>"
    refute Map.has_key?(payload, "raw_rfc822")

    assert_receive {:imap_fake_command, ^fake, :fetch, metadata_fetch}, 1_000
    assert metadata_fetch =~ "BODYSTRUCTURE"
    assert metadata_fetch =~ "BODY.PEEK[HEADER]"
    refute metadata_fetch =~ "RFC822"

    assert_receive {:imap_fake_command, ^fake, :fetch, text_fetch}, 1_000
    assert text_fetch =~ "BODY.PEEK[1]"

    assert_receive {:imap_fake_command, ^fake, :fetch, html_fetch}, 1_000
    assert html_fetch =~ "BODY.PEEK[2]"

    assert :ok = ImapAdapter.mark_as_read(client, payload["seq"])
    assert FakeImapServer.seen?(fake)

    assert :ok = ImapAdapter.disconnect(client)
    assert_receive {:imap_fake_command, ^fake, :store, _}, 1_000
    assert_receive {:imap_fake_command, ^fake, :logout, _}, 1_000
  end

  test "fetch_unseen reads single-part text body from section 1" do
    fake =
      start_supervised!(
        {FakeImapServer,
         owner: self(),
         message: %{
           subject: "Plain only",
           rfc822: "RAW-EMAIL",
           body_structure: ~s|("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 11 NIL NIL NIL)|,
           body_sections: %{"1" => "plain only"}
         }}
      )

    config = FakeImapServer.config(fake)
    assert {:ok, client} = ImapAdapter.connect(config, "INBOX")

    assert :ok =
             ImapAdapter.fetch_unseen(client, "INBOX", fn payload ->
               send(self(), {:single_part_payload, payload})
             end)

    assert_receive {:single_part_payload, payload}, 1_000
    assert payload["body_text"] == "plain only"
    assert payload["body_html"] == nil

    assert_receive {:imap_fake_command, ^fake, :fetch, metadata_fetch}, 1_000
    assert metadata_fetch =~ "BODYSTRUCTURE"

    assert_receive {:imap_fake_command, ^fake, :fetch, text_fetch}, 1_000
    assert text_fetch =~ "BODY.PEEK[1]"

    assert :ok = ImapAdapter.disconnect(client)
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

  test "fetch_unseen/3 sets references to nil when header lacks References" do
    fake =
      start_supervised!(
        {FakeImapServer,
         owner: self(), message: %{subject: "No refs"}, header: "Subject: No refs"}
      )

    config = FakeImapServer.config(fake)
    assert {:ok, client} = ImapAdapter.connect(config, "INBOX")

    assert :ok =
             ImapAdapter.fetch_unseen(client, "INBOX", fn payload ->
               send(self(), {:no_refs_payload, payload})
             end)

    assert_receive {:no_refs_payload, payload}, 1_000
    assert payload["references"] == nil

    assert :ok = ImapAdapter.disconnect(client)
  end

  test "download_attachment verifies UIDVALIDITY and fetches one UID BODY.PEEK section" do
    fake =
      start_supervised!(
        {FakeImapServer,
         owner: self(),
         message: %{
           uid: 4_281,
           body_sections: %{"2.1" => Base.encode64("attachment-bytes")}
         }}
      )

    config = FakeImapServer.config(fake)

    locator = %{
      "mailbox" => "INBOX",
      "uid_validity" => 1_193_810_872,
      "uid" => 4_281,
      "section" => "2.1",
      "encoding" => "base64"
    }

    assert {:ok, "attachment-bytes"} = ImapAdapter.download_attachment(config, locator)

    assert_receive {:imap_fake_command, ^fake, :uid, uid_fetch}, 1_000
    assert uid_fetch =~ "UID FETCH 4281"
    assert uid_fetch =~ "BODY.PEEK[2.1]"
    refute uid_fetch =~ "RFC822"
  end

  test "download_attachment rejects stale UIDVALIDITY" do
    fake = start_supervised!({FakeImapServer, owner: self(), uid_validity: 10})
    config = FakeImapServer.config(fake)

    locator = %{"mailbox" => "INBOX", "uid_validity" => 11, "uid" => 101, "section" => "1"}

    assert {:error, :stale_imap_uidvalidity} = ImapAdapter.download_attachment(config, locator)
  end

  test "disconnect/1 suppresses logout and cancel errors after server closes" do
    fake = start_supervised!({FakeImapServer, owner: self()})
    config = FakeImapServer.config(fake)
    assert {:ok, client} = ImapAdapter.connect(config, "INBOX")

    GenServer.stop(fake)

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

  test "list_mailboxes/1 reports invalid UTF-8 and still logs out" do
    fake = start_supervised!({FakeImapServer, owner: self(), invalid_mailbox: <<0xFF>>})

    assert {:error, {:list_mailboxes_failed, :invalid_utf8_mailbox_name}} =
             ImapAdapter.list_mailboxes(FakeImapServer.config(fake))

    assert_receive {:imap_fake_command, ^fake, :logout, _}, 1_000
  end

  test "download_attachment rejects malformed locator before connecting" do
    for locator <- [
          %{},
          %{"mailbox" => "INBOX", "uid_validity" => 0, "uid" => 1, "section" => "1"},
          %{"mailbox" => "INBOX", "uid_validity" => -1, "uid" => 1, "section" => "1"},
          %{"mailbox" => "INBOX", "uid_validity" => "1x", "uid" => 1, "section" => "1"},
          %{"mailbox" => "INBOX", "uid_validity" => 1, "uid" => 1, "section" => ""},
          %{"mailbox" => "INBOX", "uid_validity" => 1, "uid" => 1, "section" => ""}
        ] do
      assert {:error, :invalid_media_request} = ImapAdapter.download_attachment(%{}, locator)
    end
  end

  property "positive integer strings are accepted by locator validation" do
    check all(uid <- positive_integer_string()) do
      locator = %{
        "mailbox" => "INBOX",
        "uid_validity" => uid,
        "uid" => uid,
        "section" => "1"
      }

      assert {:error, :invalid_imap_url} = ImapAdapter.download_attachment(%{}, locator)
    end
  end

  test "download_attachment returns stale UIDVALIDITY when STATUS and SELECT omit it" do
    fake =
      start_supervised!(
        {FakeImapServer, owner: self(), uid_validity: 10, omit_uid_validity: true}
      )

    locator = %{"mailbox" => "INBOX", "uid_validity" => 10, "uid" => 101, "section" => "1"}

    assert {:error, :stale_imap_uidvalidity} =
             ImapAdapter.download_attachment(FakeImapServer.config(fake), locator)

    assert_receive {:imap_fake_command, ^fake, :logout, _}, 1_000
  end

  test "download_attachment returns decode and missing-section errors" do
    invalid =
      start_supervised!(
        {FakeImapServer, owner: self(), message: %{body_sections: %{"1" => "not base64"}}}
      )

    locator = %{
      "mailbox" => "INBOX",
      "uid_validity" => 1_193_810_872,
      "uid" => 101,
      "section" => "1",
      "encoding" => "base64"
    }

    assert {:error, :decode_failed} =
             ImapAdapter.download_attachment(FakeImapServer.config(invalid), locator)

    missing =
      start_supervised!(
        {FakeImapServer, owner: self(), message: %{body_sections: %{}}, missing_sections: ["9"]},
        id: :missing_section_fake
      )

    locator = %{locator | "encoding" => "7bit", "section" => "9"}

    assert {:error, :email_body_section_not_found} =
             ImapAdapter.download_attachment(FakeImapServer.config(missing), locator)
  end

  test "disconnect and mark_as_read normalize dead client exits" do
    client = spawn(fn -> Process.sleep(:infinity) end)
    Process.exit(client, :kill)
    ref = Process.monitor(client)
    assert_receive {:DOWN, ^ref, :process, ^client, _reason}
    assert :ok = ImapAdapter.disconnect(client)
    assert {:error, {:mark_as_read_failed, _}} = ImapAdapter.mark_as_read(client, 1)
  end

  test "silent and immediately closed fake servers return tagged connection errors" do
    silent = start_supervised!({FakeImapServer, silent_greeting: true}, id: :silent_fake)

    assert {:error, _} =
             ImapAdapter.connect(FakeImapServer.config(silent, %{timeout: 50}), "INBOX")

    assert {:error, _} = ImapAdapter.connect(%{url: "imap://127.0.0.1:1", timeout: 50}, "INBOX")
  end

  test "list_mailboxes normalizes unexpected connect replies", context do
    use_imap_mock(context)
    expect(ImapClientMock, :connect, fn _, _, _, _ -> :unexpected end)

    assert {:error, {:connect_failed, :unexpected}} =
             ImapAdapter.list_mailboxes(%{url: "imap://example.test"})
  end

  test "connect exceptions are tagged and logged", context do
    use_imap_mock(context)
    expect(ImapClientMock, :connect, fn _, _, _, _ -> raise "connect boom" end)

    log =
      capture_log(fn ->
        assert {:error, {:connect_failed, message}} =
                 ImapAdapter.list_mailboxes(%{url: "imap://example.test"})

        assert message =~ "connect boom"
      end)

    assert log =~ "connect exception"
    assert log =~ "connect boom"
  end

  test "fetch_unseen normalizes search exits", context do
    use_imap_mock(context)
    expect(ImapClientMock, :status, fn _, _, _ -> 1 end)
    expect(ImapClientMock, :search, fn _, _, _, _ -> exit(:search_failed) end)

    assert {:error, {:imap_fetch_failed, :search_failed}} =
             ImapAdapter.fetch_unseen(self(), "INBOX", fn _ -> :ok end)
  end

  test "fetch_body_section normalizes malformed replies and exits", context do
    use_imap_mock(context)
    expect(ImapClientMock, :fetch, fn _, _, _, _, _ -> :unexpected end)

    assert {:error, {:imap_fetch_failed, message}} =
             ImapAdapter.fetch_body_section(self(), 1, "1")

    assert message =~ "no match"

    expect(ImapClientMock, :fetch, fn _, _, _, _, _ -> exit(:fetch_failed) end)

    assert {:error, {:imap_fetch_failed, :fetch_failed}} =
             ImapAdapter.fetch_body_section(self(), 1, "1")
  end

  test "mark_as_read normalizes collaborator raises", context do
    use_imap_mock(context)
    expect(ImapClientMock, :add_flags, fn _, _, _ -> raise "flag boom" end)
    assert {:error, {:mark_as_read_failed, "flag boom"}} = ImapAdapter.mark_as_read(self(), 1)
  end

  test "download_attachment rejects non-map media requests" do
    assert {:error, :invalid_media_request} = ImapAdapter.download_attachment(:invalid, %{})
    assert {:error, :invalid_media_request} = ImapAdapter.download_attachment(%{}, :invalid)
  end

  test "disconnect suppresses cancel errors without requiring logout", context do
    use_imap_mock(context)
    expect(ImapClientMock, :cancel_idle, fn _ -> raise "cancel boom" end)
    assert :ok = ImapAdapter.disconnect(self())
  end

  test "fetch_unseen accepts all documented UIDVALIDITY status shapes", context do
    use_imap_mock(context)

    for {status, expected} <- [
          {{:ok, %{"uid_validity" => 7}}, 7},
          {{:ok, %{uid_validity: 8}}, 8},
          {%{"uid_validity" => 9}, 9},
          {10, 10}
        ] do
      expect(ImapClientMock, :status, fn _, _, _ -> status end)

      expect(ImapClientMock, :search, fn _, _, _, callback ->
        callback.({1, %{uid: 101}})
        :ok
      end)

      assert :ok =
               ImapAdapter.fetch_unseen(self(), "INBOX", fn payload ->
                 send(self(), {:uid, payload["uid_validity"]})
               end)

      assert_receive {:uid, ^expected}
    end
  end

  test "fetch_unseen falls back through status and state failures", context do
    use_imap_mock(context)

    for {status, state, expected} <- [
          {:unsupported, %{uid_validity: 11}, 11},
          {{:raise, "status boom"}, %{"uid_validity" => 12}, 12},
          {{:exit, :status_failed}, %{uid_validity: 13}, 13},
          {{:raise, "status boom"}, {:raise, "state boom"}, nil},
          {{:exit, :status_failed}, {:exit, :state_failed}, nil}
        ] do
      expect(ImapClientMock, :status, fn _, _, _ -> reply(status) end)
      expect(ImapClientMock, :state, fn _ -> reply(state) end)

      expect(ImapClientMock, :search, fn _, _, _, callback ->
        callback.({1, %{uid: 101}})
        :ok
      end)

      assert :ok =
               ImapAdapter.fetch_unseen(self(), "INBOX", fn payload ->
                 send(self(), {:fallback_uid, payload["uid_validity"]})
               end)

      assert_receive {:fallback_uid, ^expected}
    end
  end

  test "fetch_body_section recognizes map response key shapes", context do
    use_imap_mock(context)

    for response <- [
          %{"BODY.PEEK[1]" => "body"},
          %{"BODY[1]" => "body"},
          %{:header => "body"},
          %{:"BODY.PEEK[1]" => "body"},
          %{1 => "body"}
        ] do
      expect(ImapClientMock, :fetch, fn _, _, _, _, _ -> {:ok, [response]} end)

      result =
        ImapAdapter.fetch_body_section(
          self(),
          1,
          if(Map.has_key?(response, :header), do: "HEADER", else: "1")
        )

      expected =
        if Map.has_key?(response, 1),
          do: {:error, :email_body_section_not_found},
          else: {:ok, "body"}

      assert result == expected
    end
  end

  test "connection exits are normalized and logged", context do
    use_imap_mock(context)

    for reason <- [{:noproc, :detail}, :econnrefused] do
      expect(ImapClientMock, :connect, fn _, _, _, _ -> exit(reason) end)

      log =
        capture_log(fn ->
          assert {:error, {:connect_failed, normalized}} =
                   ImapAdapter.list_mailboxes(%{url: "imap://example.test"})

          assert normalized == if(is_tuple(reason), do: :noproc, else: reason)
        end)

      assert log =~ "connect exit"
      assert log =~ inspect(if(is_tuple(reason), do: :noproc, else: reason))
    end
  end

  test "SSL collaborator receives fallback depth", context do
    use_imap_mock(context)

    expect(ImapClientMock, :connect, fn _, _, _, opts ->
      send(self(), {:imap_opts, opts})
      {:error, :failed}
    end)

    assert {:error, :failed} =
             ImapAdapter.connect(
               %{url: "imap://example.test", ssl: true, ssl_depth: "bad"},
               "INBOX"
             )

    assert_receive {:imap_opts, opts}
    assert opts[:ssl_opts][:depth] == 3
  end

  defp reply({:raise, message}), do: raise(message)
  defp reply({:exit, reason}), do: exit(reason)
  defp reply(value), do: value

  defp positive_integer_string do
    gen all(value <- integer(1..1_000_000)) do
      Integer.to_string(value)
    end
  end
end
