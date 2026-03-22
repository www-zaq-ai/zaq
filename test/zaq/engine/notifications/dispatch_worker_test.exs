defmodule Zaq.Engine.Notifications.DispatchWorkerTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Notifications.{DispatchWorker, NotificationLog}
  alias Zaq.Repo

  # ---------------------------------------------------------------------------
  # Test adapter stubs — defined inline so no external dependency is needed
  # ---------------------------------------------------------------------------

  defmodule OkAdapter do
    def send(_identifier, _payload, _metadata), do: :ok
  end

  defmodule ErrorAdapter do
    def send(_identifier, _payload, _metadata), do: {:error, :delivery_failed}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_log(attrs \\ %{}) do
    defaults = %{sender: "system", payload: %{"subject" => "S", "body" => "B"}}
    {:ok, log} = NotificationLog.create_log(Map.merge(defaults, attrs))
    log
  end

  defp channel(platform, adapter) do
    %{
      "platform" => platform,
      "identifier" => "test@example.com",
      "adapter" => to_string(adapter)
    }
  end

  defp perform(args) do
    DispatchWorker.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 1})
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "perform/1" do
    test "reads payload from notification_logs, not job args" do
      log = create_log(%{payload: %{"subject" => "Hello", "body" => "World"}})

      # Job args contain no payload — only log_id and channels
      args = %{"log_id" => log.id, "channels" => [channel("email", OkAdapter)]}
      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.payload["subject"] == "Hello"
    end

    test "successful adapter call → attempt appended, log marked :sent" do
      log = create_log()
      args = %{"log_id" => log.id, "channels" => [channel("email", OkAdapter)]}

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "sent"
      assert length(reloaded.channels_tried) == 1
      assert hd(reloaded.channels_tried)["status"] == "ok"
    end

    test "successful adapter call → stops after first success, does not try remaining channels" do
      log = create_log()

      args = %{
        "log_id" => log.id,
        "channels" => [channel("email", OkAdapter), channel("mattermost", ErrorAdapter)]
      }

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "sent"
      assert length(reloaded.channels_tried) == 1
      assert hd(reloaded.channels_tried)["platform"] == "email"
    end

    test "all channels fail → all attempts logged, log marked :failed, returns :ok (no retry)" do
      log = create_log()

      args = %{
        "log_id" => log.id,
        "channels" => [channel("email", ErrorAdapter), channel("mattermost", ErrorAdapter)]
      }

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "failed"
      assert length(reloaded.channels_tried) == 2
      assert Enum.all?(reloaded.channels_tried, &(&1["status"] == "error"))
    end

    test "empty channels list → log marked :failed immediately" do
      log = create_log()
      args = %{"log_id" => log.id, "channels" => []}

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "failed"
      assert reloaded.channels_tried == []
    end

    test "first channel fails, second succeeds → log marked :sent" do
      log = create_log()

      args = %{
        "log_id" => log.id,
        "channels" => [channel("email", ErrorAdapter), channel("mattermost", OkAdapter)]
      }

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "sent"
      assert length(reloaded.channels_tried) == 2
      platforms = Enum.map(reloaded.channels_tried, & &1["platform"])
      assert "email" in platforms
      assert "mattermost" in platforms
    end
  end
end
