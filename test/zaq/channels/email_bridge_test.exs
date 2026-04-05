defmodule Zaq.Channels.EmailBridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge
  alias Zaq.Engine.Notifications.EmailNotification

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
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = EmailBridge.to_internal(%{}, %{})
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
