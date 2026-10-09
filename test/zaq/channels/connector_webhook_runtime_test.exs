defmodule Zaq.Channels.ConnectorWebhookRuntimeTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.{Api, JidoChatBridge, Supervisor}
  alias Zaq.Event

  defmodule Adapter do
    def delete_ingress_subscription(_bridge_id, _subscription_id, _opts),
      do: raise("runtime reconciliation must not delete webhooks")

    def list_ingress_subscriptions(_bridge_id, _opts),
      do: raise("runtime reconciliation must not inspect webhooks")
  end

  test "already-disabled webhook connector stops and retries without Repo ownership or provider IO" do
    channels = Application.fetch_env!(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :mattermost, %{
        bridge: JidoChatBridge,
        adapter: Adapter,
        ingress_mode: :webhook
      })
    )

    config = %{
      id: System.unique_integer([:positive]) + 900_000,
      provider: "mattermost",
      kind: "retrieval",
      enabled: false,
      url: "https://archive.example.invalid",
      token: "resolved",
      settings: %{}
    }

    bridge_id = "#{config.provider}_#{config.id}"

    on_exit(fn ->
      Supervisor.stop_bridge_runtime(config, bridge_id)
      Application.put_env(:zaq, :channels, channels)
    end)

    # No DataCase, persisted connector or Sandbox owner: Repo access is unavailable.
    listener = %{id: bridge_id, start: {Agent, :start_link, [fn -> :running end]}}
    assert {:ok, _} = Supervisor.start_runtime(bridge_id, nil, [listener])

    event =
      Event.new(%{before_config: config, after_config: config}, :channels,
        opts: [action: :connector_sync_runtime, confidential: true]
      )

    assert %{response: :ok} = Api.handle_event(event, :connector_sync_runtime, nil)
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id)
    assert %{response: :ok} = Api.handle_event(event, :connector_sync_runtime, nil)
  end
end
