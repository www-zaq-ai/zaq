defmodule Zaq.Engine.ConnectorEnablementTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures
  alias Zaq.Engine.{Api, ChannelConfig, ConnectorLifecycle}
  alias Zaq.Event

  defmodule Router do
    def dispatch(event) do
      config = Zaq.Repo.get!(ChannelConfig, event.request.after_config.id)
      send(self(), {:runtime_sync, event.opts[:action], config.enabled})
      %{event | response: Process.get(:runtime_response, :ok)}
    end
  end

  setup do
    actor = %{user_id: super_admin_fixture(%{must_change_password: false}).id}

    config =
      Repo.insert!(%ChannelConfig{
        provider: "whatsapp",
        kind: "retrieval",
        name: "paired",
        url: "",
        token: "",
        enabled: false,
        settings: %{}
      })

    %{actor: actor, config: config}
  end

  test "existing lifecycle route persists enablement before runtime sync", context do
    assert {:ok, %{enabled: true, runtime: :ok}} = command(context, true)
    assert_received {:runtime_sync, :sync_channel_runtime, true}
    assert Repo.get!(ChannelConfig, context.config.id).enabled
  end

  test "disable cleanup failure preserves enabled state", context do
    config = context.config |> Ecto.Changeset.change(enabled: true) |> Repo.update!()
    Process.put(:runtime_response, {:error, {:disable_failed, :logout_unavailable}})

    assert {:error, {:disable_failed, :logout_unavailable}} =
             command(%{context | config: config}, false)

    assert_received {:runtime_sync, :sync_channel_runtime, true}
    assert Repo.get!(ChannelConfig, config.id).enabled
  end

  test "runtime failure retains persisted state and reports the failure", context do
    Process.put(:runtime_response, {:error, :offline})
    assert {:ok, %{enabled: true, runtime: {:error, :offline}}} = command(context, true)
    assert Repo.get!(ChannelConfig, context.config.id).enabled
  end

  test "current actor permissions are checked in Engine", context do
    actor = %{user_id: staff_fixture(%{must_change_password: false}).id}
    assert {:error, :unauthorized} = command(%{context | actor: actor}, true)
    refute Repo.get!(ChannelConfig, context.config.id).enabled
    refute_received {:runtime_sync, _, _}
  end

  test "stale revision is rejected before runtime effects", context do
    event = event(context, true)
    context.config |> Ecto.Changeset.change(name: "changed") |> Repo.update!()

    assert %{response: {:error, :stale_connector}} =
             Api.handle_event(event, :connector_lifecycle, nil)

    refute_received {:runtime_sync, _, _}
  end

  test "confidentiality and runtime capability remain required", context do
    for opts <- [[], [confidential: true], [connector_lifecycle: true]] do
      event = %{event(context, true) | opts: opts}

      assert %{response: {:error, :unauthorized}} =
               Api.handle_event(event, :connector_lifecycle, nil)
    end

    refute Repo.get!(ChannelConfig, context.config.id).enabled
  end

  property "nonboolean desired states never mutate a connector", context do
    check all(invalid <- one_of([integer(), binary(), constant(nil)])) do
      assert {:error, :invalid_request} = command(context, invalid)
      refute Repo.get!(ChannelConfig, context.config.id).enabled
    end
  end

  defp command(context, enabled),
    do: Api.handle_event(event(context, enabled), :connector_lifecycle, nil).response

  defp event(%{config: config, actor: actor}, enabled) do
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)

    Event.new(
      %{operation: :set_enabled, request: Map.put(descriptor, :enabled, enabled)},
      :engine,
      actor: actor,
      opts: [confidential: true, connector_lifecycle: true, router: Router]
    )
  end
end
