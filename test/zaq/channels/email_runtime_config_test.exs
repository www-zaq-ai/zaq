defmodule Zaq.Channels.EmailRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.{Api, CommunicationBridge, Supervisor}
  alias Zaq.Event

  defmodule Adapter do
    def runtime_specs(config, bridge_id, _opts) do
      listener = %{
        id: bridge_id,
        start: {Agent, :start_link, [fn -> config end]}
      }

      {:ok, {nil, [listener]}}
    end
  end

  setup do
    channels = Application.fetch_env!(:zaq, :channels)
    Application.put_env(:zaq, :channels, put_in(channels, [:email, :adapter], Adapter))

    config = %{
      id: System.unique_integer([:positive]) + 900_000,
      provider: "email:imap",
      kind: "retrieval",
      enabled: true,
      url: "imap.example.invalid",
      token: "first-password",
      settings: %{
        "imap" => %{"username" => "inbox@example.com", "selected_mailboxes" => ["INBOX"]}
      }
    }

    on_exit(fn ->
      Supervisor.stop_listener(config)
      Application.put_env(:zaq, :channels, channels)
    end)

    %{config: config}
  end

  test "supplied config starts and restarts the exact email listener without Repo access", ctx do
    # No SQL Sandbox ownership and no persisted connector: a Repo reload must fail.
    assert :ok = CommunicationBridge.sync_provider_runtime(ctx.config)
    assert {:ok, %{listener_pids: [first]}} = Supervisor.lookup_runtime(bridge_id(ctx.config))
    assert Agent.get(first, & &1).token == "first-password"

    monitor = Process.monitor(first)
    updated = %{ctx.config | token: "changed-password"}
    assert :ok = CommunicationBridge.sync_provider_runtime(updated)
    assert_receive {:DOWN, ^monitor, :process, ^first, _}
    assert {:ok, %{listener_pids: [second]}} = Supervisor.lookup_runtime(bridge_id(updated))
    assert second != first
    assert Agent.get(second, & &1).token == "changed-password"

    assert :ok = CommunicationBridge.sync_provider_runtime(%{updated | enabled: false})
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id(updated))
    assert :ok = CommunicationBridge.sync_provider_runtime(%{updated | enabled: false})
  end

  test "runtime event requires confidentiality, not a database-backed BO actor", ctx do
    event = Event.new(%{config: ctx.config}, :channels, opts: [action: :sync_provider_runtime])

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(event, :sync_provider_runtime, nil)

    event = %{event | opts: [action: :sync_provider_runtime, confidential: true]}
    assert %{response: :ok} = Api.handle_event(event, :sync_provider_runtime, nil)
    assert {:ok, %{listener_pids: [_]}} = Supervisor.lookup_runtime(bridge_id(ctx.config))
  end

  test "updating one of two supplied connectors never restarts its sibling", ctx do
    sibling = %{ctx.config | id: ctx.config.id + 1, token: "sibling-password"}
    on_exit(fn -> Supervisor.stop_listener(sibling) end)

    assert :ok = CommunicationBridge.sync_provider_runtime(ctx.config)
    assert :ok = CommunicationBridge.sync_provider_runtime(sibling)
    assert {:ok, %{listener_pids: [sibling_pid]}} = Supervisor.lookup_runtime(bridge_id(sibling))
    assert :ok = CommunicationBridge.sync_provider_runtime(%{ctx.config | token: "updated"})
    assert {:ok, %{listener_pids: [^sibling_pid]}} = Supervisor.lookup_runtime(bridge_id(sibling))
    assert Agent.get(sibling_pid, & &1).token == "sibling-password"
  end

  test "archive runtime stop and retry are Repo-free even when persisted config is already disabled",
       ctx do
    assert :ok = CommunicationBridge.sync_provider_runtime(ctx.config)
    disabled = %{ctx.config | enabled: false}

    event =
      Event.new(%{before_config: disabled, after_config: disabled}, :channels,
        opts: [action: :connector_sync_runtime, confidential: true]
      )

    assert %{response: :ok} = Api.handle_event(event, :connector_sync_runtime, nil)
    assert {:error, :not_running} = Supervisor.lookup_runtime(bridge_id(disabled))
    assert %{response: :ok} = Api.handle_event(event, :connector_sync_runtime, nil)
  end

  test "supplied-config runtime rejects incomplete identity or enablement" do
    for config <- [
          %{},
          %{provider: "email:imap"},
          %{id: 42, provider: "email:imap", enabled: "true"}
        ] do
      assert {:error, :invalid_runtime_config} = CommunicationBridge.sync_provider_runtime(config)
    end
  end

  defp bridge_id(config), do: "#{config.provider}_#{config.id}"
end
