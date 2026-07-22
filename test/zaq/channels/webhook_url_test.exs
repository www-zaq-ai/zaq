defmodule Zaq.Channels.WebhookUrlTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.WebhookUrl
  alias Zaq.System

  setup do
    previous_base_url = System.get_global_base_url()

    on_exit(fn -> :ok = System.set_global_base_url(previous_base_url) end)

    :ok
  end

  test "build! raises when global base URL is unset" do
    :ok = System.set_global_base_url(nil)

    assert_raise ArgumentError, "global base URL is required to build webhook URL", fn ->
      WebhookUrl.build!(:data_source, :google_drive)
    end
  end

  test "build returns nil when type segment is not a string or atom" do
    :ok = System.set_global_base_url("https://zaq.example")

    assert WebhookUrl.build(123, :google_drive) == nil
  end

  test "build returns nil when provider segment is not a string or atom" do
    :ok = System.set_global_base_url("https://zaq.example")

    assert WebhookUrl.build(:data_source, %{provider: :google_drive}) == nil
  end

  test "build constructs channel webhook URL for any channel type" do
    :ok = System.set_global_base_url("https://zaq.example/base/")

    assert WebhookUrl.build(:data_source, :google_drive) ==
             "https://zaq.example/base/channels/webhook/data_source/google_drive"

    assert WebhookUrl.build(:conversation, "mattermost") ==
             "https://zaq.example/base/channels/webhook/conversation/mattermost"
  end
end
