defmodule Zaq.Channels.LinkedDevice.ConnectorDisableTest do
  use Zaq.DataCase, async: false

  import Zaq.AccountsFixtures

  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.{ChannelConfig, LinkedDeviceConfirmation}
  alias Zaq.{Event, NodeRouter}

  defmodule OfflineTransport do
    def connect(config, opts) do
      Amarula.Testing.start_offline(
        profile: config.profile,
        storage: config.storage,
        parent_pid: Keyword.fetch!(opts, :parent)
      )
    end

    defdelegate stop(conn, opts), to: AmarulaClient
    defdelegate logout(conn, opts), to: AmarulaClient
  end

  defmodule OfflineAdapter do
    use Jido.Chat.Adapter

    defdelegate channel_type(), to: Adapter
    defdelegate capabilities(), to: Adapter
    defdelegate prepare_connection(opts), to: Adapter
    defdelegate connection_profile(binding), to: Adapter
    defdelegate storage_runtime_spec(opts), to: Adapter
    defdelegate send_message(room, text, opts), to: Adapter
    defdelegate transform_incoming(payload), to: Adapter
    defdelegate logout(listener), to: Adapter

    def listener_child_specs(id, opts) do
      ingress = opts |> Keyword.fetch!(:ingress) |> Map.put(:transport, OfflineTransport)
      Adapter.listener_child_specs(id, Keyword.put(opts, :ingress, ingress))
    end
  end

  setup do
    previous = Application.fetch_env!(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      whatsapp: %{
        bridge: JidoChatBridge,
        adapter: OfflineAdapter,
        ingress_mode: :linked_device
      }
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    assert :ok = JidoChatBridge.start_runtime({:provider, :whatsapp}, [])
    %{actor: %{user_id: super_admin_fixture(%{must_change_password: false}).id}}
  end

  test "confirmed disable crosses real role boundaries and clears only its profile stores", %{
    actor: actor
  } do
    first = connector(actor, "+15550001")
    second = connector(actor, "+15550002")
    first_options = start_connector(first)
    second_options = start_connector(second)
    first_scope = Amarula.Storage.scope(first_options.storage)
    second_scope = Amarula.Storage.scope(second_options.storage)

    for {options, scope} <- [{first_options, first_scope}, {second_options, second_scope}] do
      assert :ok = Amarula.Storage.put(scope, options.profile, :creds, :logout_marker, "paired")
      assert :ok = Amarula.Storage.put(scope, options.profile, :session, "peer", "ratchet")
    end

    assert {:ok, descriptor} = command(first, :context, actor)

    assert {:ok, %{status: :disabled, runtime: :synced}} =
             dispatch(Map.put(descriptor, :op, :disable), actor)

    refute Repo.get!(ChannelConfig, first.id).enabled
    assert Repo.get!(ChannelConfig, second.id).enabled

    assert {:error, :not_running} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(first))

    assert {:ok, "paired"} =
             Amarula.Storage.get(second_scope, second_options.profile, :creds, :logout_marker)

    assert {:ok, "ratchet"} =
             Amarula.Storage.get(second_scope, second_options.profile, :session, "peer")

    # Re-enabling storage access cannot restore credentials erased by logout.
    Repo.get!(ChannelConfig, first.id) |> Ecto.Changeset.change(enabled: true) |> Repo.update!()

    assert :error =
             Amarula.Storage.get(first_scope, first_options.profile, :creds, :logout_marker)

    assert :error = Amarula.Storage.get(first_scope, first_options.profile, :session, "peer")
  end

  test "archive logs out and stops the selected saved profile before hiding it", %{actor: actor} do
    first = connector(actor, "+15550003")
    second = connector(actor, "+15550004")
    start_connector(first)
    start_connector(second)

    event =
      Event.new(
        %{channel_config_id: first.id, provider: first.provider, kind: first.kind},
        :engine,
        actor: actor,
        opts: [action: :archive_channel_connector, confidential: true]
      )

    assert {:ok, %{status: :archived, runtime: :synced}} = NodeRouter.dispatch(event).response

    assert %ChannelConfig{enabled: false, archived_at: %DateTime{}} =
             Repo.get!(ChannelConfig, first.id)

    assert {:error, :not_running} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(first))

    assert %ChannelConfig{enabled: true, archived_at: nil} = Repo.get!(ChannelConfig, second.id)

    assert {:ok, _} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(second))
  end

  defp connector(actor, phone) do
    {:ok, config} =
      LinkedDeviceConfirmation.save(%{
        attempt_id: Ecto.UUID.generate(),
        identity: %{phone_number: phone},
        owner_id: actor.user_id,
        records: %{{"creds", "bootstrap"} => "opaque"}
      })

    on_exit(fn -> JidoChatBridge.stop_runtime(config) end)
    config
  end

  defp start_connector(config) do
    assert {:ok, options} = JidoChatBridge.saved_connection_options(config, OfflineAdapter)
    assert :ok = JidoChatBridge.start_runtime(config)
    options
  end

  defp command(config, op, actor),
    do:
      dispatch(
        %{op: op, channel_config_id: config.id, provider: config.provider, kind: config.kind},
        actor
      )

  defp dispatch(request, actor) do
    Event.new(request, :engine,
      actor: actor,
      opts: [action: :disable_channel_connector, confidential: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end
end
