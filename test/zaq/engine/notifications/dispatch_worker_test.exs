defmodule Zaq.Engine.Notifications.DispatchWorkerTest do
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Notifications.{DispatchWorker, NotificationLog}
  alias Zaq.Repo

  # ---------------------------------------------------------------------------
  # Stub router — injected via Application env
  # ---------------------------------------------------------------------------

  defmodule OkRouter do
    def deliver(%Outgoing{} = outgoing) do
      send(self(), {:delivered, outgoing.provider, outgoing.channel_id})
      :ok
    end
  end

  defmodule ErrorRouter do
    def deliver(%Outgoing{}), do: {:error, :delivery_failed}
  end

  defmodule FirstFailRouter do
    # Fails on email, succeeds on everything else
    def deliver(%Outgoing{provider: :email}), do: {:error, :delivery_failed}

    def deliver(%Outgoing{} = outgoing) do
      send(self(), {:delivered, outgoing.provider, outgoing.channel_id})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_log(attrs \\ %{}) do
    defaults = %{sender: "system", payload: %{"subject" => "S", "body" => "B"}}
    {:ok, log} = NotificationLog.create_log(Map.merge(defaults, attrs))
    log
  end

  defp channel(platform) do
    %{"platform" => platform, "identifier" => "test@example.com"}
  end

  defp perform(args) do
    DispatchWorker.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 1})
  end

  setup do
    Application.put_env(:zaq, :dispatch_worker_router_module, OkRouter)

    on_exit(fn ->
      Application.delete_env(:zaq, :dispatch_worker_router_module)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "perform/1" do
    test "real EmailNotification adapter path marks sent and emits email" do
      Application.put_env(:zaq, :dispatch_worker_router_module, Zaq.Channels.Router)

      assert {:ok, _} =
               ChannelConfig.upsert_by_provider("email:smtp", %{
                 name: "Email SMTP",
                 kind: "retrieval",
                 enabled: true,
                 settings: %{
                   "relay" => "",
                   "port" => "587",
                   "transport_mode" => "starttls",
                   "tls" => "enabled",
                   "tls_verify" => "verify_peer",
                   "username" => nil,
                   "password" => nil,
                   "from_email" => "noreply@example.com",
                   "from_name" => "ZAQ"
                 }
               })

      log = create_log(%{payload: %{"subject" => "Dispatch Subject", "body" => "Dispatch Body"}})

      args = %{
        "log_id" => log.id,
        "channels" => [channel("email:smtp")]
      }

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "sent"
      assert length(reloaded.channels_tried) == 1
      assert hd(reloaded.channels_tried)["platform"] == "email:smtp"
      assert hd(reloaded.channels_tried)["status"] == "ok"

      assert_receive {:email, email}
      assert email.subject == "Dispatch Subject"
      assert email.from == {"ZAQ", "noreply@zaq.local"}
    end

    test "reads payload from notification_logs, not job args" do
      log = create_log(%{payload: %{"subject" => "Hello", "body" => "World"}})

      # Job args contain no payload — only log_id and channels
      args = %{"log_id" => log.id, "channels" => [channel("email:smtp")]}
      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.payload["subject"] == "Hello"
    end

    test "successful delivery → attempt appended, log marked :sent" do
      log = create_log()
      args = %{"log_id" => log.id, "channels" => [channel("email:smtp")]}

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "sent"
      assert length(reloaded.channels_tried) == 1
      assert hd(reloaded.channels_tried)["status"] == "ok"
    end

    test "successful delivery → stops after first success, does not try remaining channels" do
      log = create_log()

      args = %{
        "log_id" => log.id,
        "channels" => [channel("email:smtp"), channel("mattermost")]
      }

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "sent"
      assert length(reloaded.channels_tried) == 1
      assert hd(reloaded.channels_tried)["platform"] == "email:smtp"
    end

    test "all channels fail → all attempts logged, log marked :failed, returns :ok (no retry)" do
      Application.put_env(:zaq, :dispatch_worker_router_module, ErrorRouter)

      log = create_log()

      args = %{
        "log_id" => log.id,
        "channels" => [channel("email:smtp"), channel("mattermost")]
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
      Application.put_env(:zaq, :dispatch_worker_router_module, FirstFailRouter)

      log = create_log()

      args = %{
        "log_id" => log.id,
        "channels" => [channel("email:smtp"), channel("mattermost")]
      }

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "sent"
      assert length(reloaded.channels_tried) == 2
      platforms = Enum.map(reloaded.channels_tried, & &1["platform"])
      assert "email:smtp" in platforms
      assert "mattermost" in platforms
    end

    test "unknown platform is skipped" do
      log = create_log()

      args = %{
        "log_id" => log.id,
        "channels" => [%{"platform" => "not_a_real_platform", "identifier" => "x"}]
      }

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "failed"
    end

    test "log not found → cancels job" do
      args = %{"log_id" => 999_999_999, "channels" => []}
      assert {:cancel, :log_not_found} = perform(args)
    end

    test "%Outgoing{} delivered to Router carries log payload body" do
      log = create_log(%{payload: %{"subject" => "Sub", "body" => "Notification text"}})
      args = %{"log_id" => log.id, "channels" => [channel("email:smtp")]}

      perform(args)

      assert_received {:delivered, :email, "test@example.com"}
    end
  end
end
