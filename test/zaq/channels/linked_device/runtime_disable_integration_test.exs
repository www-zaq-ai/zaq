defmodule Zaq.Channels.LinkedDevice.RuntimeDisableIntegrationTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Zaq.Repo

  import Zaq.AccountsFixtures

  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient
  alias Zaq.Accounts
  alias Zaq.Channels.{Bridge, ConnectorRuntime, JidoChatBridge}
  alias Zaq.Engine.Actions.ConfirmLinkedDevice
  alias Zaq.Engine.{ChannelConfig, ConnectorLifecycle}
  alias Zaq.{Event, NodeRouter}

  defmodule OfflineTransport do
    alias Jido.Chat.WhatsApp.Transport.GuardedStorage

    def connect(config, opts) do
      Amarula.Testing.start_offline(
        profile: config.profile,
        storage: {GuardedStorage, storage: config.storage, notify: Keyword.fetch!(opts, :parent)},
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
    defdelegate connection_identity(binding), to: Adapter
    defdelegate connection_options(binding, opts), to: Adapter
    defdelegate provider_child_specs(opts), to: Adapter
    defdelegate send_message(room, text, opts), to: Adapter
    defdelegate transform_incoming(payload), to: Adapter
    defdelegate logout(listener), to: Adapter
    defdelegate cleanup_connection(binding, opts), to: Adapter

    def listener_child_specs(id, opts) do
      ingress = opts |> Keyword.fetch!(:ingress) |> Map.put(:transport, OfflineTransport)
      Adapter.listener_child_specs(id, Keyword.put(opts, :ingress, ingress))
    end
  end

  defmodule ActivationFailAdapter do
    use Jido.Chat.Adapter
    defdelegate channel_type(), to: Adapter
    defdelegate capabilities(), to: Adapter
    defdelegate prepare_connection(opts), to: Adapter
    defdelegate connection_identity(binding), to: Adapter
    defdelegate connection_options(binding, opts), to: Adapter
    defdelegate provider_child_specs(opts), to: Adapter
    defdelegate send_message(room, text, opts), to: Adapter
    defdelegate transform_incoming(payload), to: Adapter
    defdelegate logout(listener), to: Adapter
    defdelegate cleanup_connection(binding, opts), to: Adapter
    def listener_child_specs(_, _), do: {:error, :activation_failed}
  end

  defmodule UnavailableRouter do
    def dispatch(event), do: %{event | response: {:error, :channels_unavailable}}
  end

  defmodule ObservedBridge do
    def build_runtime_specs(config) do
      send(self(), {:runtime_config, config})
      {:error, :observed}
    end

    def runtime_supervisor_module, do: __MODULE__
    def runtime_bridge_id(config), do: "observed_#{config.id}"

    def stop_bridge_runtime(config, _id) do
      send(self(), {:runtime_config, config})
      :ok
    end
  end

  setup %{conn: conn} do
    Mox.stub(Zaq.NodeRouterMock, :find_node, fn _ -> node() end)
    Zaq.WhatsAppFixtures.configure_channels(OfflineAdapter)
    assert :ok = JidoChatBridge.start_runtime({:provider, :whatsapp}, [])
    user = super_admin_fixture(%{must_change_password: false})
    %{actor: %{user_id: user.id}, conn: init_test_session(conn, %{user_id: user.id})}
  end

  for operation <- [:disable, :archive] do
    test "#{operation} cleans a saved account whose activation failed", %{
      actor: actor,
      conn: conn
    } do
      selected = connector(actor, "+15550005")
      other = connector(actor, "+15550006")

      assert {:ok, prepared} =
               Jido.Chat.Adapter.prepare_connection(OfflineAdapter,
                 sink_mfa: Zaq.WhatsAppFixtures.private_sink(selected)
               )

      options = Keyword.fetch!(prepared, :ingress)
      scope = Amarula.Storage.scope(options.storage)
      assert :ok = Amarula.Storage.put(scope, options.profile, :session, "peer", "ratchet")

      channels = Application.fetch_env!(:zaq, :channels)

      Application.put_env(
        :zaq,
        :channels,
        put_in(channels, [:whatsapp, :adapter], ActivationFailAdapter)
      )

      assert {:error, :activation_failed} = JidoChatBridge.start_runtime(selected)

      assert {:error, :not_running} =
               Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(selected))

      case unquote(operation) do
        :disable ->
          view = confirm_disable(conn, selected)
          assert render(view) =~ "disabled"

        :archive ->
          event =
            Event.new(
              %{channel_config_id: selected.id, provider: selected.provider, kind: selected.kind},
              :engine,
              actor: actor,
              opts: [
                action: :archive_channel_connector,
                confidential: true,
                skip_permissions: true
              ]
            )

          assert {:ok, %{status: :archived}} = NodeRouter.dispatch(event).response
      end

      refute Repo.get!(ChannelConfig, selected.id).enabled
      assert Repo.get!(ChannelConfig, other.id).enabled
      selected = Repo.get!(ChannelConfig, selected.id)
      assert selected.settings["credential_document_id"]
      selected |> Ecto.Changeset.change(enabled: true, archived_at: nil) |> Repo.update!()
      assert :error = Amarula.Storage.get(scope, options.profile, :session, "peer")
      assert :error = Amarula.Storage.get(scope, options.profile, :creds, :bootstrap)
    end
  end

  test "missing saved binding is not provisioned during offline cleanup", %{
    actor: actor,
    conn: conn
  } do
    selected = connector(actor, "+15550007")
    settings = Map.delete(selected.settings, "credential_document_id")
    selected = selected |> Ecto.Changeset.change(settings: settings) |> Repo.update!()
    view = confirm_disable(conn, selected)
    assert render(view) =~ "Could not disable"

    assert Repo.get!(ChannelConfig, selected.id).enabled
    refute Repo.get!(ChannelConfig, selected.id).settings["credential_document_id"]
  end

  test "shared enable sync reuses the selected saved profile and listener", %{actor: actor} do
    selected = connector(actor, "+15550010")
    before = %{selected | enabled: false}

    event =
      Event.new(
        %{
          before_config: ChannelConfig.to_runtime_config(before),
          after_config: ChannelConfig.to_runtime_config(selected)
        },
        :channels,
        actor: actor,
        opts: [action: :sync_channel_runtime, confidential: true]
      )

    assert :ok = NodeRouter.dispatch(event).response
    bridge_id = JidoChatBridge.runtime_bridge_id(selected)
    assert {:ok, %{listener_pids: [first]}} = Zaq.Channels.Supervisor.lookup_runtime(bridge_id)

    assert :ok = NodeRouter.dispatch(event).response
    assert {:ok, %{listener_pids: [^first]}} = Zaq.Channels.Supervisor.lookup_runtime(bridge_id)

    assert Repo.get!(ChannelConfig, selected.id).settings["credential_document_id"] ==
             selected.settings["credential_document_id"]
  end

  test "runtime snapshot requires the confidential runtime capability", %{actor: actor} do
    selected = connector(actor, "+15550009")
    request = %{channel_config_id: selected.id, provider: selected.provider, kind: selected.kind}

    for opts <- [
          [action: :connector_runtime_context],
          [action: :connector_runtime_context, confidential: true]
        ] do
      assert {:error, :unauthorized} =
               NodeRouter.dispatch(Event.new(request, :engine, opts: opts)).response
    end
  end

  test "linked-device continuation retains session authority without revalidating the operator",
       %{
         actor: actor
       } do
    config = connector(actor, "+15550017")

    request = %{
      before_config: ChannelConfig.to_runtime_config(%{config | enabled: false}),
      after_config: ChannelConfig.to_runtime_config(config),
      phase: :before_persist
    }

    event =
      Event.new(request, :channels,
        actor: actor,
        opts: [action: :connector_sync_runtime, confidential: true, skip_permissions: true]
      )

    assert {:ok, %{continuation: :after_persist}} = NodeRouter.dispatch(event).response

    Accounts.get_user!(actor.user_id)
    |> Ecto.Changeset.change(must_change_password: true)
    |> Repo.update!()

    assert {:ok, %{runtime: :complete}} =
             NodeRouter.dispatch(%{event | request: %{request | phase: :after_persist}}).response

    assert Repo.get!(ChannelConfig, config.id).enabled

    assert {:ok, _} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(config))
  end

  test "startup and restart consume fresh saved configuration without Channels self-dispatch", %{
    actor: actor
  } do
    stale = connector(actor, "+15550014")
    current = stale |> Ecto.Changeset.change(name: "Fresh name") |> Repo.update!()

    # These paths should route only to Engine to resolve the saved binding.
    Mox.stub(Zaq.NodeRouterMock, :find_node, fn :engine -> node() end)
    assert {:ok, %{name: "Fresh name"}} = ConnectorRuntime.current_config(stale)

    assert {:error, :observed} = Bridge.start_runtime(ObservedBridge, stale, [])
    assert_received {:runtime_config, %{name: "Fresh name"}}
    assert {:error, :observed} = Bridge.restart_runtime(ObservedBridge, stale)
    assert_received {:runtime_config, %{name: "Fresh name"}}
    assert_received {:runtime_config, %{name: "Fresh name"}}

    assert :ok = JidoChatBridge.start_runtime(stale)

    assert {:ok, state_pid} =
             Zaq.Channels.Supervisor.lookup_state_pid(JidoChatBridge.runtime_bridge_id(current))

    assert :sys.get_state(state_pid).config.name == "Fresh name"

    current |> Ecto.Changeset.change(name: "Refreshed name") |> Repo.update!()
    assert :ok = JidoChatBridge.start_runtime(stale)
    assert :sys.get_state(state_pid).config.name == "Refreshed name"
  end

  test "stale saved snapshots cannot start or restart disabled or archived connectors", %{
    actor: actor
  } do
    for {phone, change} <- [
          {"+15550015", [enabled: false]},
          {"+15550016",
           [enabled: false, archived_at: DateTime.utc_now() |> DateTime.truncate(:second)]}
        ] do
      stale = connector(actor, phone)
      stale |> Ecto.Changeset.change(change) |> Repo.update!()

      assert {:error, :connector_unavailable} = ConnectorRuntime.current_config(stale)
      assert {:error, :connector_unavailable} = Bridge.start_runtime(ObservedBridge, stale, [])
      assert {:error, :connector_unavailable} = Bridge.restart_runtime(ObservedBridge, stale)
      assert {:error, :connector_unavailable} = JidoChatBridge.start_runtime(stale)
      refute_received {:runtime_config, _}

      assert {:error, :not_running} =
               Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(stale))
    end
  end

  test "confirmed disable crosses real role boundaries and clears only its profile stores", %{
    actor: actor,
    conn: conn
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

    view = confirm_disable(conn, first)
    assert render(view) =~ "disabled"

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
        opts: [action: :archive_channel_connector, confidential: true, skip_permissions: true]
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

  test "archive after unavailable disable still clears the selected saved credentials", %{
    actor: actor
  } do
    selected = connector(actor, "+15550012")
    other = connector(actor, "+15550013")
    options = start_connector(selected)
    scope = Amarula.Storage.scope(options.storage)
    assert :ok = Amarula.Storage.put(scope, options.profile, :session, "peer", "ratchet")

    {:ok, descriptor} =
      ConnectorLifecycle.context(selected.id, selected.provider, selected.kind)

    assert {:error, :unavailable} =
             ConnectorLifecycle.execute(
               %{operation: :set_enabled, request: Map.put(descriptor, :enabled, false)},
               actor,
               router: UnavailableRouter,
               skip_permissions: true
             )

    assert Repo.get!(ChannelConfig, selected.id).enabled
    assert {:ok, "ratchet"} = Amarula.Storage.get(scope, options.profile, :session, "peer")

    event =
      Event.new(Map.take(descriptor, [:channel_config_id, :provider, :kind, :revision]), :engine,
        actor: actor,
        opts: [action: :archive_channel_connector, confidential: true, skip_permissions: true]
      )

    assert {:ok, %{status: :archived}} = NodeRouter.dispatch(event).response
    assert Repo.get!(ChannelConfig, other.id).enabled

    Repo.get!(ChannelConfig, selected.id)
    |> Ecto.Changeset.change(enabled: true, archived_at: nil)
    |> Repo.update!()

    assert :error = Amarula.Storage.get(scope, options.profile, :session, "peer")
    assert :error = Amarula.Storage.get(scope, options.profile, :creds, :bootstrap)
  end

  test "real disable confirmation rejects a changed profile before teardown", %{
    conn: conn,
    actor: actor
  } do
    config = connector(actor, "+15550011")
    start_connector(config)
    view = open_disable(conn, config)

    config |> Ecto.Changeset.change(name: "Changed") |> Repo.update!()

    view |> element("#confirm-disable-config-button") |> render_click()
    assert Repo.get!(ChannelConfig, config.id).enabled

    assert {:ok, _} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(config))
  end

  test "disable confirmation uses the authenticated BO session's authorization", %{
    conn: conn,
    actor: actor
  } do
    config = connector(actor, "+15550018")
    start_connector(config)
    view = open_disable(conn, config)

    Accounts.get_user!(actor.user_id)
    |> Ecto.Changeset.change(must_change_password: true)
    |> Repo.update!()

    view |> element("#confirm-disable-config-button") |> render_click()
    refute Repo.get!(ChannelConfig, config.id).enabled

    assert {:error, :not_running} =
             Zaq.Channels.Supervisor.lookup_runtime(JidoChatBridge.runtime_bridge_id(config))
  end

  defp connector(actor, phone) do
    {:ok, %{result: {:ok, config}}} =
      ConfirmLinkedDevice.run(
        %{
          request: %{
            attempt_id: Ecto.UUID.generate(),
            provider: "whatsapp",
            account: %{external_id: phone},
            owner_id: actor.user_id,
            credentials: %{{"creds", "bootstrap"} => "opaque"}
          }
        },
        %{actor: actor, linked_device_runtime: true, skip_permissions: true}
      )

    on_exit(fn -> JidoChatBridge.stop_runtime(config) end)
    config
  end

  defp start_connector(config) do
    assert {:ok, prepared} =
             Jido.Chat.Adapter.prepare_connection(OfflineAdapter,
               sink_mfa: Zaq.WhatsAppFixtures.private_sink(config)
             )

    options = Keyword.fetch!(prepared, :ingress)
    assert :ok = JidoChatBridge.start_runtime(config)
    options
  end

  defp confirm_disable(conn, config) do
    view = open_disable(conn, config)
    view |> element("#confirm-disable-config-button") |> render_click()
    view
  end

  defp open_disable(conn, config) do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/whatsapp")
    view |> element("#toggle-config-#{config.id}") |> render_click()
    assert Repo.get!(ChannelConfig, config.id).enabled
    assert has_element?(view, "#confirm-disable-config-button")
    view
  end
end
