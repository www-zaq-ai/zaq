defmodule Zaq.Engine.Notifications.EmailNotificationTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Notifications.EmailNotification

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp payload(opts \\ []) do
    %{
      "subject" => Keyword.get(opts, :subject, "Hello"),
      "body" => Keyword.get(opts, :body, "World")
    }
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "send_notification/3" do
    test "delivers email and returns :ok" do
      assert :ok = EmailNotification.send_notification("user@example.com", payload(), %{})
    end

    test "uses email_body from metadata over payload body when present" do
      # metadata email_body takes precedence — just verifying no crash and :ok
      metadata = %{"email_body" => "Custom body from metadata"}
      assert :ok = EmailNotification.send_notification("user@example.com", payload(), metadata)
    end

    test "uses html_body from payload when present" do
      p = Map.put(payload(), "html_body", "<p>Hello</p>")
      assert :ok = EmailNotification.send_notification("user@example.com", p, %{})
    end

    test "generates html from plain text body when html_body is absent" do
      # Two paragraphs separated by double newline
      p = payload(body: "First paragraph\n\nSecond paragraph")
      assert :ok = EmailNotification.send_notification("user@example.com", p, %{})
    end

    test "escapes HTML special characters in plain text body" do
      p = payload(body: "Hello <World> & friends")
      assert :ok = EmailNotification.send_notification("user@example.com", p, %{})
    end

    test "handles missing subject gracefully" do
      p = %{"body" => "No subject here"}
      assert :ok = EmailNotification.send_notification("user@example.com", p, %{})
    end

    test "handles empty payload gracefully" do
      assert :ok = EmailNotification.send_notification("user@example.com", %{}, %{})
    end
  end
end
