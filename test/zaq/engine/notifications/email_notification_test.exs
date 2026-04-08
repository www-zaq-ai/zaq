defmodule Zaq.Engine.Notifications.EmailNotificationTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Channels.ChannelConfig
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

    attrs = Map.merge(defaults, attrs)

    assert {:ok, _channel} = ChannelConfig.upsert_by_provider("email:smtp", attrs)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "send_notification/3" do
    test "delivers with default sender when channel config is missing" do
      assert :ok = EmailNotification.send_notification("user@example.com", payload(), %{})

      assert_receive {:email, email}
      assert email.subject == "Hello"
      assert email.from == {"ZAQ", "noreply@zaq.local"}
    end

    test "delivers email and returns :ok" do
      upsert_smtp_channel()

      assert :ok = EmailNotification.send_notification("user@example.com", payload(), %{})

      assert_receive {:email, email}
      assert email.subject == "Hello"
      assert email.from == {"ZAQ", "noreply@zaq.local"}
    end

    test "uses email_body from metadata over payload body when present" do
      upsert_smtp_channel()

      metadata = %{"email_body" => "Custom body from metadata"}
      assert :ok = EmailNotification.send_notification("user@example.com", payload(), metadata)

      assert_receive {:email, email}
      assert email.text_body == "Custom body from metadata"
    end

    test "uses html_body from payload when present" do
      upsert_smtp_channel()

      p = Map.put(payload(), "html_body", "<p>Hello</p>")
      assert :ok = EmailNotification.send_notification("user@example.com", p, %{})

      assert_receive {:email, email}
      assert email.html_body == "<p>Hello</p>"
    end

    test "generates html from plain text body when html_body is absent" do
      upsert_smtp_channel()

      p = payload(body: "First paragraph\n\nSecond paragraph")
      assert :ok = EmailNotification.send_notification("user@example.com", p, %{})

      assert_receive {:email, email}
      assert email.html_body =~ "<p>First paragraph</p>"
      assert email.html_body =~ "<p>Second paragraph</p>"
    end

    test "escapes HTML special characters in plain text body" do
      upsert_smtp_channel()

      p = payload(body: "Hello <World> & friends")
      assert :ok = EmailNotification.send_notification("user@example.com", p, %{})

      assert_receive {:email, email}
      assert email.html_body =~ "Hello &lt;World&gt; &amp; friends"
    end

    test "handles missing subject gracefully" do
      upsert_smtp_channel()

      p = %{"body" => "No subject here"}
      assert :ok = EmailNotification.send_notification("user@example.com", p, %{})

      assert_receive {:email, email}
      assert email.subject == ""
    end

    test "handles empty payload gracefully" do
      upsert_smtp_channel()

      assert :ok = EmailNotification.send_notification("user@example.com", %{}, %{})

      assert_receive {:email, email}
      assert email.subject == ""
    end

    test "uses relay blank path and still delivers through test adapter" do
      upsert_smtp_channel(%{settings: smtp_settings(%{"relay" => ""})})

      assert :ok = EmailNotification.send_notification("user@example.com", payload(), %{})
      assert_receive {:email, _email}
    end

    test "uses ssl transport mode branch" do
      upsert_smtp_channel(%{
        settings:
          smtp_settings(%{
            "relay" => "smtp.example.com",
            "transport_mode" => "ssl",
            "port" => "465"
          })
      })

      assert {:error, _reason} =
               EmailNotification.send_notification("user@example.com", payload(), %{})
    end

    test "handles username with invalid encrypted password without crashing" do
      upsert_smtp_channel(%{
        settings:
          smtp_settings(%{
            "relay" => "smtp.example.com",
            "username" => "user@example.com",
            "password" => "enc:v1:broken:payload"
          })
      })

      assert {:error, _reason} =
               EmailNotification.send_notification("user@example.com", payload(), %{})
    end

    test "uses sender provided in payload" do
      upsert_smtp_channel(%{
        settings: smtp_settings(%{"from_name" => "ZAQ Bot", "from_email" => "bot@example.com"})
      })

      p = Map.merge(payload(), %{"from_name" => "ZAQ Bot", "from_email" => "bot@example.com"})

      assert :ok = EmailNotification.send_notification("user@example.com", p, %{})

      assert_receive {:email, email}
      assert email.from == {"ZAQ Bot", "bot@example.com"}
    end

    test "uses sender provided in metadata as map" do
      upsert_smtp_channel()

      metadata = %{"from" => %{"name" => "ZAQ Agent", "email" => "agent@example.com"}}

      assert :ok = EmailNotification.send_notification("user@example.com", payload(), metadata)

      assert_receive {:email, email}
      assert email.from == {"ZAQ Agent", "agent@example.com"}
    end

    test "applies custom SMTP headers from metadata" do
      upsert_smtp_channel()

      metadata = %{
        "headers" => %{
          "In-Reply-To" => "<msg-2@example.com>",
          "References" => "<msg-1@example.com> <msg-2@example.com>"
        }
      }

      assert :ok = EmailNotification.send_notification("user@example.com", payload(), metadata)

      assert_receive {:email, email}
      assert {"In-Reply-To", "<msg-2@example.com>"} in email.headers
      assert {"References", "<msg-1@example.com> <msg-2@example.com>"} in email.headers
    end
  end
end
