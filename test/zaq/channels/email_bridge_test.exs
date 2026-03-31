defmodule Zaq.Channels.EmailBridgeTest do
  use Zaq.DataCase, async: false
  import Swoosh.TestAssertions

  alias Zaq.Channels.EmailBridge
  alias Zaq.Engine.Messages.Outgoing

  describe "to_internal/2" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = EmailBridge.to_internal(%{}, %{})
    end
  end

  describe "send_reply/2" do
    test "delivers email to channel_id recipient and returns :ok" do
      outgoing = %Outgoing{
        body: "Hello there",
        channel_id: "recipient@example.com",
        provider: :email
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})
      assert_email_sent(to: [{"", "recipient@example.com"}])
    end

    test "uses subject from atom key in metadata" do
      outgoing = %Outgoing{
        body: "Body text",
        channel_id: "user@example.com",
        provider: :email,
        metadata: %{subject: "Atom Subject"}
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})
      assert_email_sent(subject: "Atom Subject")
    end

    test "uses subject from string key in metadata" do
      outgoing = %Outgoing{
        body: "Body text",
        channel_id: "user@example.com",
        provider: :email,
        metadata: %{"subject" => "String Subject"}
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})
      assert_email_sent(subject: "String Subject")
    end

    test "falls back to default subject when none in metadata" do
      outgoing = %Outgoing{
        body: "Body text",
        channel_id: "user@example.com",
        provider: :email,
        metadata: %{}
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})
      assert_email_sent(subject: "Notification from ZAQ")
    end

    test "uses html_body from metadata when present" do
      outgoing = %Outgoing{
        body: "Plain text",
        channel_id: "user@example.com",
        provider: :email,
        metadata: %{html_body: "<strong>Custom HTML</strong>"}
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})
      assert_email_sent(html_body: "<strong>Custom HTML</strong>")
    end

    test "generates html from body when no html_body in metadata" do
      outgoing = %Outgoing{
        body: "First paragraph\n\nSecond paragraph",
        channel_id: "user@example.com",
        provider: :email,
        metadata: %{}
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})
      assert_email_sent(html_body: "<p>First paragraph</p><p>Second paragraph</p>")
    end

    test "html-escapes special characters in body" do
      outgoing = %Outgoing{
        body: "Hello <World> & 'Friends'",
        channel_id: "user@example.com",
        provider: :email,
        metadata: %{}
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})
      assert_email_sent(html_body: "<p>Hello &lt;World&gt; &amp; 'Friends'</p>")
    end

    test "wraps multi-line paragraph lines with <br>" do
      outgoing = %Outgoing{
        body: "Line one\nLine two",
        channel_id: "user@example.com",
        provider: :email,
        metadata: %{}
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})
      assert_email_sent(html_body: "<p>Line one<br>Line two</p>")
    end

    test "skips blank paragraphs" do
      outgoing = %Outgoing{
        body: "First\n\n\n\nSecond",
        channel_id: "user@example.com",
        provider: :email,
        metadata: %{}
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})
      assert_email_sent(html_body: "<p>First</p><p>Second</p>")
    end
  end
end
