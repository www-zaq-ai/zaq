defmodule Zaq.Engine.ConnectorArchiveWebhookTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{Api, JidoChatBridge, Supervisor}
  alias Zaq.Engine.{ChannelConfig, ConnectorLifecycle}
  alias Zaq.Event

  defmodule Adapter do
    def list_ingress_subscriptions(_bridge_id, _opts),
      do: {:ok, [%{subscription_id: "archive-webhook"}]}

    def delete_ingress_subscription(bridge_id, _subscription_id, _opts) do
      send(self(), {:delete_webhook, bridge_id})
      count = Process.get(:webhook_delete_count, 0) + 1
      Process.put(:webhook_delete_count, count)
      if count == 1, do: {:ok, %{deleted: true}}, else: {:error, :already_deleted}
    end
  end

  defmodule RuntimeSupervisor do
    def stop_bridge_runtime(config, bridge_id) do
      send(self(), {:stop_runtime, bridge_id})

      case Process.delete(:runtime_stop_failure) do
        nil -> Supervisor.stop_bridge_runtime(config, bridge_id)
        reason -> {:error, reason}
      end
    end
  end

  defmodule Router do
    def dispatch(%Event{} = event) do
      assert event.opts[:confidential]
      Api.handle_event(event, event.opts[:action], nil)
    end
  end

  setup do
    channels = Application.fetch_env!(:zaq, :channels)
    supervisor = Application.fetch_env(:zaq, :chat_bridge_supervisor_module)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :mattermost, %{
        bridge: JidoChatBridge,
        adapter: Adapter,
        ingress_mode: :webhook
      })
    )

    Application.put_env(:zaq, :chat_bridge_supervisor_module, RuntimeSupervisor)

    on_exit(fn ->
      Application.put_env(:zaq, :channels, channels)

      case supervisor do
        {:ok, value} -> Application.put_env(:zaq, :chat_bridge_supervisor_module, value)
        :error -> Application.delete_env(:zaq, :chat_bridge_supervisor_module)
      end
    end)

    :ok
  end

  test "archive and retry use real Jido callbacks: one webhook deletion and runtime-only stop" do
    config = insert_config()
    sibling = insert_config()
    bridge_id = start_runtime(config)
    sibling_id = start_runtime(sibling)

    assert {:ok, %{status: :archived, ingress: :deleted, runtime: :synced}} = archive(config)
    assert_received {:delete_webhook, ^bridge_id}
    assert_received {:stop_runtime, ^bridge_id}
    refute_received {:delete_webhook, _}
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)
    assert {:ok, _} = Supervisor.lookup_runtime(sibling_id)
    assert Repo.get!(ChannelConfig, config.id).archived_at

    assert {:ok, %{status: :already_archived, ingress: :already_archived, runtime: :synced}} =
             archive(config)

    assert_received {:stop_runtime, ^bridge_id}
    refute_received {:delete_webhook, _}
    assert Process.get(:webhook_delete_count) == 1
  end

  test "post-commit stop failure stays pending and retry stops without another webhook deletion" do
    config = insert_config()
    bridge_id = start_runtime(config)
    Process.put(:runtime_stop_failure, :runtime_down)

    assert {:ok, %{status: :archived, runtime: {:pending, :runtime_down}}} = archive(config)
    assert_received {:delete_webhook, ^bridge_id}
    assert_received {:stop_runtime, ^bridge_id}
    assert Repo.get!(ChannelConfig, config.id).archived_at
    assert {:ok, _} = Supervisor.lookup_runtime(bridge_id)

    assert {:ok, %{status: :already_archived, runtime: :synced}} = archive(config)
    assert_received {:stop_runtime, ^bridge_id}
    refute_received {:delete_webhook, _}
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)
  end

  test "ordinary enabled-to-disabled updates still stop runtime and tear down their own ingress" do
    config = insert_config() |> ChannelConfig.to_runtime_config()
    bridge_id = start_runtime(config)

    assert :ok = JidoChatBridge.sync_runtime(config, %{config | enabled: false})
    assert_received {:stop_runtime, ^bridge_id}
    assert_received {:delete_webhook, ^bridge_id}
    refute_received {:delete_webhook, _}
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)
  end

  defp archive(config) do
    ConnectorLifecycle.archive(
      %{channel_config_id: config.id, provider: config.provider, kind: config.kind},
      %{user_id: 1},
      router: Router
    )
  end

  defp insert_config do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "webhook-#{System.unique_integer([:positive])}",
      provider: "mattermost",
      kind: "retrieval",
      enabled: true,
      url: "https://archive.example.invalid",
      token: "archive-token",
      settings: %{}
    })
    |> Repo.insert!()
  end

  defp start_runtime(config) do
    bridge_id = "#{config.provider}_#{config.id}"
    listener = %{id: bridge_id, start: {Agent, :start_link, [fn -> :running end]}}
    assert {:ok, _} = Supervisor.start_runtime(bridge_id, nil, [listener])
    on_exit(fn -> Supervisor.stop_bridge_runtime(config, bridge_id) end)
    bridge_id
  end
end
