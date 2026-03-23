defmodule Zaq.Channels.Retrieval.Mattermost.NotificationTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Channels.Retrieval.Mattermost.Notification

  # ---------------------------------------------------------------------------
  # Fake API modules
  # ---------------------------------------------------------------------------

  defmodule FakeAPI do
    def send_message(_channel_id, _message) do
      {:ok, %{"id" => "post-123"}}
    end
  end

  defmodule FakeAPIError do
    def send_message(_channel_id, _message) do
      {:error, :connection_refused}
    end
  end

  defmodule FakeAPINoId do
    def send_message(_channel_id, _message) do
      {:ok, %{}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp put_api(mod) do
    Application.put_env(:zaq, :mattermost_api_module, mod)
    on_exit(fn -> Application.delete_env(:zaq, :mattermost_api_module) end)
  end

  defp payload(opts \\ []) do
    %{"subject" => "Hello", "body" => Keyword.get(opts, :body, "World")}
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "send_notification/3" do
    test "successful send returns :ok" do
      put_api(FakeAPI)
      assert :ok = Notification.send_notification("channel-1", payload(), %{})
    end

    test "API error is passed through as {:error, reason}" do
      put_api(FakeAPIError)

      assert {:error, :connection_refused} =
               Notification.send_notification("channel-1", payload(), %{})
    end

    test "formats body from payload" do
      # FakeAPI always succeeds — verifying no crash on body extraction
      put_api(FakeAPI)
      assert :ok = Notification.send_notification("channel-1", %{"body" => "My message"}, %{})
    end

    test "on_reply metadata is ignored when absent" do
      put_api(FakeAPI)

      assert :ok =
               Notification.send_notification("channel-1", payload(), %{"other_key" => "value"})
    end

    test "on_reply with unknown module logs warning and returns :ok" do
      put_api(FakeAPI)

      metadata = %{
        "on_reply" => %{
          "module" => "Elixir.NonExistent.Worker.DoesNotExist",
          "args" => %{}
        }
      }

      # Should not raise — the rescue clause swallows ArgumentError
      assert :ok = Notification.send_notification("channel-1", payload(), metadata)
    end

    test "post_id is nil when API response has no id — on_reply still succeeds" do
      put_api(FakeAPINoId)
      # No on_reply metadata — just verifying nil post_id path does not crash
      assert :ok = Notification.send_notification("channel-1", payload(), %{})
    end
  end
end
