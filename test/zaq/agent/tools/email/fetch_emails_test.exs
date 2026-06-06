defmodule Zaq.Agent.Tools.Email.FetchEmailsTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.Tools.Email.FetchEmails
  alias Zaq.TestSupport.FakeImapServer

  defp with_public_key_stub(source, fun) do
    {:public_key, original_binary, original_path} = :code.get_object_code(:public_key)

    stub_dir =
      Path.join([
        System.tmp_dir!(),
        "zaq_fetch_emails_public_key_stub",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    File.mkdir_p!(stub_dir)
    stub_path = Path.join(stub_dir, "public_key.erl")
    File.write!(stub_path, source)

    {:ok, :public_key, stub_binary} = :compile.file(String.to_charlist(stub_path), [:binary])

    :code.purge(:public_key)
    :code.delete(:public_key)
    {:module, :public_key} = :code.load_binary(:public_key, ~c"public_key.beam", stub_binary)

    try do
      fun.()
    after
      :code.purge(:public_key)
      :code.delete(:public_key)
      {:module, :public_key} = :code.load_binary(:public_key, original_path, original_binary)
      File.rm_rf!(stub_dir)
    end
  end

  describe "run/2 — invalid IMAP config" do
    test "returns error when imap_config has no URL" do
      config = %{url: "", username: "u", password: "p", ssl: false, timeout: 500}
      assert {:error, :invalid_imap_url} = FetchEmails.run(%{imap_config: config}, %{})
    end

    test "returns error when connection is refused (bad host/port)" do
      config = %{
        url: "imap://127.0.0.1:1",
        username: "u",
        password: "p",
        ssl: false,
        timeout: 500
      }

      result = FetchEmails.run(%{imap_config: config}, %{})
      assert {:error, _reason} = result
    end

    test "non-TLS configs do not require system CA certs" do
      config = %{url: "", username: "u", password: "p", ssl: false, timeout: 500}

      with_public_key_stub(
        """
        -module(public_key).
        -export([cacerts_get/0]).

        cacerts_get() ->
            erlang:error(cacerts_unavailable).
        """,
        fn ->
          assert {:error, :invalid_imap_url} = FetchEmails.run(%{imap_config: config}, %{})
        end
      )
    end
  end

  describe "run/2 — FakeImapServer with unseen messages" do
    setup do
      {:ok, server} =
        start_supervised(
          {FakeImapServer,
           [
             message: %{
               uid: 42,
               subject: "Test Subject",
               from_name: "Bob",
               from_mailbox: "bob",
               from_host: "example.com",
               message_id: "<msg-42@example.com>",
               in_reply_to: "<root@example.com>",
               references: "<root@example.com>",
               rfc822: "RAW BODY"
             },
             seen: false
           ]}
        )

      {:ok, server: server}
    end

    test "fetches unseen emails and returns count", %{server: server} do
      config = FakeImapServer.config(server)

      assert {:ok, %{emails: emails, count: count}, _logs} =
               FetchEmails.run(%{imap_config: config}, %{})

      assert count == length(emails)
      assert count > 0
    end

    test "emits an info log with count and mailbox", %{server: server} do
      config = FakeImapServer.config(server)
      assert {:ok, _result, logs: logs} = FetchEmails.run(%{imap_config: config}, %{})

      assert [%{level: "info", message: message, metadata: %{mailbox: "INBOX", count: count}}] =
               logs

      assert count > 0
      assert message =~ "INBOX"
    end

    test "returned emails have expected fields", %{server: server} do
      config = FakeImapServer.config(server)
      assert {:ok, %{emails: [email | _]}, _logs} = FetchEmails.run(%{imap_config: config}, %{})
      assert is_map(email)
      assert Map.has_key?(email, "subject")
      assert Map.has_key?(email, "from")
      assert Map.has_key?(email, "message_id")
    end

    test "uses default mailbox INBOX when mailbox param is absent", %{server: server} do
      config = FakeImapServer.config(server)
      assert {:ok, %{emails: _, count: _}, _logs} = FetchEmails.run(%{imap_config: config}, %{})
    end

    test "accepts custom mailbox param", %{server: server} do
      config = FakeImapServer.config(server)

      assert {:ok, %{emails: _, count: _}, _logs} =
               FetchEmails.run(%{imap_config: config, mailbox: "INBOX"}, %{})
    end
  end

  describe "run/2 — FakeImapServer with no unseen messages" do
    setup do
      {:ok, server} =
        start_supervised({FakeImapServer, [seen: true]})

      {:ok, server: server}
    end

    test "returns empty emails list with count 0", %{server: server} do
      config = FakeImapServer.config(server)
      assert {:ok, %{emails: [], count: 0}, _logs} = FetchEmails.run(%{imap_config: config}, %{})
    end

    test "emits an info log with count 0 when mailbox is empty", %{server: server} do
      config = FakeImapServer.config(server)
      assert {:ok, _result, logs: logs} = FetchEmails.run(%{imap_config: config}, %{})
      assert [%{level: "info", metadata: %{count: 0}}] = logs
    end
  end
end
