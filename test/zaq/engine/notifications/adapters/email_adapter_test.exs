defmodule Zaq.Engine.Notifications.Adapters.EmailAdapterTest do
  use Zaq.DataCase, async: true

  import Swoosh.TestAssertions

  alias Zaq.Engine.Notifications.Adapters.EmailAdapter

  @payload %{"subject" => "Hello", "body" => "World"}

  describe "platform/0" do
    test "returns \"email\"" do
      assert EmailAdapter.platform() == "email"
    end
  end

  describe "send/3" do
    test "delivers email to the identifier address" do
      assert :ok = EmailAdapter.send("user@example.com", @payload, %{})
      assert_email_sent(to: "user@example.com", subject: "Hello")
    end

    test "recipient address comes from identifier, not from ChannelConfig" do
      assert :ok = EmailAdapter.send("other@example.com", @payload, %{})
      assert_email_sent(to: "other@example.com")
    end

    test "sets text body from payload" do
      assert :ok = EmailAdapter.send("u@example.com", @payload, %{})
      assert_email_sent(text_body: "World")
    end

    test "uses html_body from payload when present" do
      payload = Map.put(@payload, "html_body", "<p>World</p>")
      assert :ok = EmailAdapter.send("u@example.com", payload, %{})
      assert_email_sent(html_body: "<p>World</p>")
    end

    test "generates html_body from text when html_body is nil" do
      assert :ok = EmailAdapter.send("u@example.com", @payload, %{})
      assert_email_sent(html_body: "<p>World</p>")
    end

    test "metadata is accepted and ignored" do
      assert :ok = EmailAdapter.send("u@example.com", @payload, %{"on_reply" => "irrelevant"})
    end
  end
end
