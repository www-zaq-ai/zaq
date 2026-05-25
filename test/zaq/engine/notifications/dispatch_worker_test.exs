defmodule Zaq.Engine.Notifications.DispatchWorkerTest do
  use Zaq.DataCase, async: false
  import ExUnit.CaptureLog

  @moduletag capture_log: true

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Notifications.{DispatchWorker, NotificationLog}
  alias Zaq.Repo

  # ---------------------------------------------------------------------------
  # Stub communication bridge — invoked through Channels Api
  # ---------------------------------------------------------------------------

  defmodule OkCommunicationBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      send(self(), {:delivered, outgoing.provider, outgoing.channel_id})
      :ok
    end
  end

  defmodule ErrorCommunicationBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}
    def send_reply(%Outgoing{}, _connection_details), do: {:error, :delivery_failed}
  end

  defmodule FirstFailCommunicationBridge do
    # Fails on email, succeeds on everything else
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(%Outgoing{provider: :email}, _connection_details),
      do: {:error, :delivery_failed}

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      send(self(), {:delivered, outgoing.provider, outgoing.channel_id})
      :ok
    end
  end

  defmodule StaleStatusCommunicationBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      if log_id = Process.get(:dispatch_worker_log_id) do
        _ =
          NotificationLog.transition_status(
            %NotificationLog{id: log_id, status: "pending"},
            "failed"
          )
      end

      send(self(), {:delivered, outgoing.provider, outgoing.channel_id})
      :ok
    end
  end

  defmodule StubNodeRouter do
    def dispatch(event) do
      api_module = Keyword.get(event.opts, :channels_api_module, Zaq.Channels.Api)
      action = Keyword.get(event.opts, :action, :invoke)
      api_module.handle_event(event, action, nil)
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
    Application.put_env(:zaq, :dispatch_worker_node_router_module, StubNodeRouter)

    Application.put_env(
      :zaq,
      :dispatch_worker_channels_event_opts,
      channels_api_module: Zaq.Channels.Api,
      bridge_module: OkCommunicationBridge
    )

    on_exit(fn ->
      Application.delete_env(:zaq, :dispatch_worker_node_router_module)
      Application.delete_env(:zaq, :dispatch_worker_channels_event_opts)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "perform/1" do
    test "real EmailNotification adapter path marks sent and emits email" do
      Application.put_env(
        :zaq,
        :dispatch_worker_node_router_module,
        Zaq.NodeRouter
      )

      Application.put_env(:zaq, :dispatch_worker_channels_event_opts, [])

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

    test "\"email:imap\" channel maps to :email and succeeds" do
      log = create_log()
      args = %{"log_id" => log.id, "channels" => [channel("email:imap")]}

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "sent"
      assert length(reloaded.channels_tried) == 1
      assert hd(reloaded.channels_tried)["platform"] == "email:imap"

      assert_receive {:delivered, :email, "test@example.com"}
    end

    test "reads payload from notification_logs, not job args" do
      log = create_log(%{payload: %{"subject" => "Hello", "body" => "World"}})

      # Job args contain no payload — only log_id and channels
      args = %{"log_id" => log.id, "channels" => [channel("email:smtp")]}
      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.payload["subject"] == "Hello"
    end

    test "successful delivery -> attempt appended, log marked :sent" do
      log = create_log()
      args = %{"log_id" => log.id, "channels" => [channel("email:smtp")]}

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "sent"
      assert length(reloaded.channels_tried) == 1
      assert hd(reloaded.channels_tried)["status"] == "ok"
    end

    test "successful delivery -> stops after first success, does not try remaining channels" do
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
      Application.put_env(
        :zaq,
        :dispatch_worker_channels_event_opts,
        channels_api_module: Zaq.Channels.Api,
        bridge_module: ErrorCommunicationBridge
      )

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
      Application.put_env(
        :zaq,
        :dispatch_worker_channels_event_opts,
        channels_api_module: Zaq.Channels.Api,
        bridge_module: FirstFailCommunicationBridge
      )

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

    test "non-binary platform is skipped via fallback clause and dispatch continues" do
      log = create_log()

      args = %{
        "log_id" => log.id,
        "channels" => [%{"platform" => 123, "identifier" => "ignored"}, channel("mattermost")]
      }

      assert :ok = perform(args)

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "sent"
      assert length(reloaded.channels_tried) == 1
      assert hd(reloaded.channels_tried)["platform"] == "mattermost"

      assert_receive {:delivered, :mattermost, "test@example.com"}
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

    test "log not found -> cancels job" do
      args = %{"log_id" => 999_999_999, "channels" => []}
      assert {:cancel, :log_not_found} = perform(args)
    end

    test "%Outgoing{} delivered through CommunicationBridge carries log payload body" do
      log = create_log(%{payload: %{"subject" => "Sub", "body" => "Notification text"}})
      args = %{"log_id" => log.id, "channels" => [channel("email:smtp")]}

      perform(args)

      assert_received {:delivered, :email, "test@example.com"}
    end

    test "delivery ok but status transition stale logs warning and still returns :ok" do
      Application.put_env(
        :zaq,
        :dispatch_worker_channels_event_opts,
        channels_api_module: Zaq.Channels.Api,
        bridge_module: StaleStatusCommunicationBridge
      )

      log = create_log()
      args = %{"log_id" => log.id, "channels" => [channel("email:smtp")]}

      log_output =
        capture_log(fn ->
          Process.put(:dispatch_worker_log_id, log.id)

          try do
            assert :ok = perform(args)
          after
            Process.delete(:dispatch_worker_log_id)
          end
        end)

      assert log_output =~
               "[DispatchWorker] log #{log.id} sent but status update failed: :stale_record"

      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.status == "failed"
      assert length(reloaded.channels_tried) == 1
      assert hd(reloaded.channels_tried)["status"] == "ok"
    end
  end
end
