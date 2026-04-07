defmodule Zaq.Channels.EmailBridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge
  alias Zaq.Engine.Notifications.EmailNotification

  defmodule DynamicAdapterStub do
    def to_internal(payload, connection_details) do
      send(self(), {:dynamic_adapter_called, payload, connection_details})

      %Zaq.Engine.Messages.Incoming{
        content: "ok",
        channel_id: "INBOX",
        provider: :email,
        metadata: %{}
      }
    end
  end

  defp smtp_settings(overrides \\ %{}) do
    Map.merge(
      %{
        "relay" => "",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => nil,
        "username" => nil,
        "password" => nil,
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      },
      overrides
    )
  end

  defp upsert_smtp_channel(attrs \\ %{}) do
    defaults = %{
      name: "Email SMTP",
      kind: "retrieval",
      enabled: true,
      settings: smtp_settings()
    }

    assert {:ok, _channel} =
             ChannelConfig.upsert_by_provider("email:smtp", Map.merge(defaults, attrs))

    :ok
  end

  describe "to_internal/2" do
    test "maps imap payload into Incoming message" do
      payload = %{
        "body_text" => "hello from imap",
        "body_html" => "<p>hello from imap</p>",
        "from" => %{"address" => "alice@example.com", "name" => "Alice"},
        "subject" => "Hello",
        "message_id" => "<msg-1@example.com>",
        "in_reply_to" => "<root@example.com>",
        "references" => "<a@example.com> <root@example.com>",
        "attachments" => [
          %{
            "filename" => "manual.pdf",
            "content_type" => "application/pdf",
            "download_ref" => "att-1"
          }
        ]
      }

      assert incoming =
               EmailBridge.to_internal(payload, %{
                 mailbox: "INBOX",
                 adapter: Zaq.Channels.EmailBridge.ImapAdapter
               })

      assert incoming.content == "hello from imap"
      assert incoming.channel_id == "INBOX"
      assert incoming.author_id == "alice@example.com"
      assert incoming.author_name == "Alice"
      assert incoming.thread_id == "root@example.com"
      assert incoming.message_id == "<msg-1@example.com>"
      assert incoming.provider == :email
      assert incoming.metadata["email"]["html_body"] == "<p>hello from imap</p>"

      assert [%{"filename" => "manual.pdf", "download_ref" => "att-1"}] =
               incoming.metadata["email"]["attachments"]
    end

    test "dispatches to adapter passed through connection details" do
      payload = %{"body_text" => "hello"}
      details = %{adapter: DynamicAdapterStub, mailbox: "INBOX"}

      assert %Zaq.Engine.Messages.Incoming{} = EmailBridge.to_internal(payload, details)
      assert_received {:dynamic_adapter_called, ^payload, ^details}
    end
  end

  describe "email:smtp notification delivery" do
    test "delivers notifications using the email:smtp ChannelConfig" do
      upsert_smtp_channel()

      payload = %{"subject" => "Test subject", "body" => "Test body"}

      assert :ok = EmailNotification.send_notification("recipient@example.com", payload, %{})

      assert_receive {:email, email}
      assert email.to == [{"", "recipient@example.com"}]
      assert email.subject == "Test subject"
      assert email.from == {"ZAQ", "noreply@example.com"}
    end

    test "uses default sender when no email:smtp ChannelConfig exists" do
      payload = %{"subject" => "Fallback", "body" => "Hello"}

      assert :ok = EmailNotification.send_notification("recipient@example.com", payload, %{})

      assert_receive {:email, email}
      assert email.from == {"ZAQ", "noreply@zaq.local"}
    end
  end
end
