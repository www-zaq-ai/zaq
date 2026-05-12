defmodule Zaq.Agent.Tools.Email.FetchEmailsTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Email.FetchEmails
  alias Zaq.TestSupport.FakeImapServer

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
      assert {:ok, %{emails: emails, count: count}} = FetchEmails.run(%{imap_config: config}, %{})
      assert count == length(emails)
      assert count > 0
    end

    test "returned emails have expected fields", %{server: server} do
      config = FakeImapServer.config(server)
      assert {:ok, %{emails: [email | _]}} = FetchEmails.run(%{imap_config: config}, %{})
      assert is_map(email)
      assert Map.has_key?(email, "subject")
      assert Map.has_key?(email, "from")
      assert Map.has_key?(email, "message_id")
    end

    test "uses default mailbox INBOX when mailbox param is absent", %{server: server} do
      config = FakeImapServer.config(server)
      assert {:ok, %{emails: _, count: _}} = FetchEmails.run(%{imap_config: config}, %{})
    end

    test "accepts custom mailbox param", %{server: server} do
      config = FakeImapServer.config(server)

      assert {:ok, %{emails: _, count: _}} =
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
      assert {:ok, %{emails: [], count: 0}} = FetchEmails.run(%{imap_config: config}, %{})
    end
  end
end
