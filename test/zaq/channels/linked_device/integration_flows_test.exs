defmodule Zaq.Channels.LinkedDevice.OnboardingTest do
  use Zaq.DataCase, async: false
  import Zaq.AccountsFixtures
  import Zaq.TestSupport.Eventually
  import Zaq.CredentialDocumentFixtures, only: [document: 3]
  alias Jido.Chat.WhatsApp.ConnectionWorker
  alias Zaq.Accounts
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.{Event, NodeRouter}
  alias Zaq.TestSupport.WhatsAppFlowAdapter
  alias Zaq.TestSupport.WhatsAppFlowTransport, as: Transport
  alias ZaqWeb.Live.BO.AI.BOActor
  alias ZaqWeb.Live.DeviceSignInPolling

  setup do
    Zaq.WhatsAppFixtures.configure_channels(WhatsAppFlowAdapter)
    assert :ok = JidoChatBridge.start_runtime({:provider, :whatsapp}, [])
    start_supervised!({Transport, observer: self()})

    actor =
      super_admin_fixture(%{must_change_password: false})
      |> Repo.preload(:role)
      |> BOActor.build()

    %{actor: actor}
  end

  test "scan creates no connector; confirmation saves and restores the session once", %{
    actor: actor
  } do
    count = Repo.aggregate(ChannelConfig, :count)
    assert {:ok, %{ref: session}} = sign_in({:begin, %{owner: self()}}, actor)

    assert Enum.any?(DynamicSupervisor.which_children(Zaq.Channels.BridgeSupervisor), fn
             {_, ^session, :worker, _} -> true
             _ -> false
           end)

    on_exit(fn -> sign_in({:cancel, session}, actor) end)
    assert_receive {:whatsapp_connected_config, options}
    assert Repo.aggregate(ChannelConfig, :count) == count

    assert {:error, :identity_not_ready} =
             sign_in({:confirm, session, "+15550001"}, actor)

    qr = qr(session, actor)
    assert :ok = Transport.scan(options.profile, qr)
    temporary_scope = Amarula.Storage.scope(options.storage)

    assert :ok =
             Amarula.Storage.put(temporary_scope, options.profile, :session, "peer", "ratchet")

    assert :ok =
             Amarula.Storage.put(temporary_scope, options.profile, :sender_key, "group", "key")

    assert await_status(session, actor, "confirm")
    account_id = account_id(session, actor)
    assert Repo.aggregate(ChannelConfig, :count) == count

    assert {:ok, %{status: "active", completion: %{runtime_pending: false} = saved}} =
             sign_in({:confirm, session, account_id}, actor)

    assert saved.name == "Support account"
    config = Repo.get!(ChannelConfig, saved.id)
    on_exit(fn -> JidoChatBridge.stop_runtime(config) end)

    assert {:ok, %{status: "active", completion: ^saved}} =
             sign_in({:confirm, session, account_id}, actor)

    assert Repo.aggregate(ChannelConfig, :count) == count + 1
    assert_receive {:whatsapp_connected_config, restored}
    refute restored.sync_history
    refute restored.sync_full_history
    assert restored.profile == JidoChatBridge.resolve_connection_details(config, %{}).profile
    restored_scope = Amarula.Storage.scope(restored.storage)

    assert {:ok, "ratchet"} =
             Amarula.Storage.get(restored_scope, restored.profile, :session, "peer")

    assert {:ok, "key"} =
             Amarula.Storage.get(restored_scope, restored.profile, :sender_key, "group")

    binding = %{
      channel_config_id: config.id,
      credential_id: config.settings["credential_document_id"]
    }

    for namespace <- ["session", "sender_key"] do
      assert {:ok, []} =
               document(binding, :list_keys, %{namespace: namespace})
    end

    assert {:ok, conn} = Transport.resolve_conn(profile: restored.profile)
    assert Agent.get(conn, & &1.paired?)
    assert config.settings["account"]["external_id"] == "+15550001"
  end

  test "confirmation rejects an account changed since it was displayed", %{actor: actor} do
    assert {:ok, %{ref: session}} = sign_in({:begin, %{owner: self()}}, actor)
    assert_receive {:whatsapp_connected_config, options}
    qr = qr(session, actor)
    :ok = Transport.scan(options.profile, qr)
    assert await_status(session, actor, "confirm")
    displayed_account_id = account_id(session, actor)
    {:ok, conn} = Transport.resolve_conn(profile: options.profile)

    Agent.update(
      conn,
      &Map.put(&1, :identity, %{
        phone_number: "+15550002",
        display_name: nil,
        account_jids: ["15550002@s.whatsapp.net"]
      })
    )

    worker = :sys.get_state(session).worker
    :ok = ConnectionWorker.refresh_identity(worker)
    assert identity_ready?(worker)

    assert {:ok, %{status: "failed", completion: nil, retry: :resume, summary: summary}} =
             sign_in({:confirm, session, displayed_account_id}, actor)

    assert summary =~ "The linked account changed"

    assert {:ok, %{status: "cancelled"}} = sign_in({:cancel, session}, actor)
  end

  test "a RAM seed failure retains saved pairing and reports connection pending", %{actor: actor} do
    assert {:ok, %{ref: session}} = sign_in({:begin, %{owner: self()}}, actor)
    on_exit(fn -> sign_in({:cancel, session}, actor) end)
    assert_receive {:whatsapp_connected_config, options}
    qr = qr(session, actor)
    assert :ok = Transport.scan(options.profile, qr)
    assert await_status(session, actor, "confirm")
    account_id = account_id(session, actor)

    # Fits provisional storage but exceeds the encoded per-record RAM limit.
    assert :ok =
             Amarula.Storage.put(
               Amarula.Storage.scope(options.storage),
               options.profile,
               :session,
               "peer",
               String.duplicate("s", 1024 * 1024)
             )

    assert {:ok, %{status: "active", completion: %{runtime_pending: true} = saved}} =
             sign_in({:confirm, session, account_id}, actor)

    assert {:ok, %{status: "active", completion: ^saved}} =
             sign_in({:confirm, session, account_id}, actor)

    config = Repo.get!(ChannelConfig, saved.id)
    on_exit(fn -> JidoChatBridge.stop_runtime(config) end)
    refute_received {:whatsapp_connected_config, _}

    assert :ok = JidoChatBridge.start_runtime(config)
    assert_receive {:whatsapp_connected_config, restored}
    scope = Amarula.Storage.scope(restored.storage)
    assert {:ok, %{paired: true}} = Amarula.Storage.get(scope, restored.profile, :creds, :self)
    assert :error = Amarula.Storage.get(scope, restored.profile, :session, "peer")
  end

  defp identity_ready?(worker),
    do:
      eventually(fn -> ConnectionWorker.status(worker) end,
        matches: &match?(%{identity: %{phone_number: "+15550002"}}, &1),
        timeout: 1_000,
        label: "replacement account identity"
      )

  test "owner scoping and cancellation remove provisional sessions", %{actor: actor} do
    assert {:ok, %{ref: session}} = sign_in({:begin, %{owner: self()}}, actor)
    assert_receive {:whatsapp_connected_config, options}

    other =
      super_admin_fixture(%{must_change_password: false})
      |> Repo.preload(:role)
      |> BOActor.build()

    assert {:error, :unauthorized} = sign_in({:observe, session}, other)
    assert {:ok, %{status: "cancelled"}} = sign_in({:cancel, session}, actor)
    refute Process.alive?(session)
    assert {:error, :not_connected} = Transport.resolve_conn(profile: options.profile)
  end

  test "shared sign-in commands expose an opaque ref and normalized challenge without changing session ownership",
       %{actor: actor} do
    event =
      Event.new(%{provider: "whatsapp", command: {:begin, %{owner: self()}}}, :channels,
        actor: actor,
        opts: [action: :pair_linked_device, confidential: true, skip_permissions: true]
      )

    assert {:ok, %{ref: ref, status: "pending", dismiss: :cancel, retry: :resume}} =
             NodeRouter.dispatch(event).response

    assert_receive {:whatsapp_connected_config, options}

    assert {:ok, %{challenge: %{type: :qr, value: qr}, observe: true}} =
             sign_in({:observe, ref}, actor)

    assert :ok = Transport.scan(options.profile, qr)
    assert await_status(ref, actor, "confirm")

    assert {:ok, %{status: "confirm", confirmation: %{external_id: _}, observe: false}} =
             sign_in({:observe, ref}, actor)

    other =
      super_admin_fixture(%{must_change_password: false})
      |> Repo.preload(:role)
      |> BOActor.build()

    assert {:error, _} = sign_in({:observe, ref}, other)
    monitor = Process.monitor(ref)

    assert {:ok, %{status: "cancelled", challenge: nil, observe: false}} =
             NodeRouter.dispatch(%{
               event
               | request: %{provider: "whatsapp", command: {:cancel, ref}}
             }).response

    assert_receive {:DOWN, ^monitor, :process, ^ref, :normal}, 1_000

    assert {:ok, %{status: "expired", retry: :restart, observe: false}} =
             sign_in({:observe, ref}, actor)
  end

  defp sign_in(command, actor, confidential \\ true) do
    Event.new(%{provider: "whatsapp", command: command}, :channels,
      actor: actor,
      opts: [
        action: :pair_linked_device,
        confidential: confidential,
        skip_permissions: actor[:skip_permissions] == true
      ]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  test "UI cancels abandoned sessions and closes the active session without stale-result interference",
       %{actor: actor} do
    Mox.stub(Zaq.NodeRouterMock, :find_node, fn _ -> node() end)
    assert {:ok, %{ref: active}} = sign_in({:begin, %{owner: self()}}, actor)
    assert {:ok, %{ref: abandoned}} = sign_in({:begin, %{owner: self()}}, actor)
    active_monitor = Process.monitor(active)
    abandoned_monitor = Process.monitor(abandoned)
    dispatch = &sign_in(&1, actor)

    {:ok, active_view} =
      Zaq.SignIn.view(active, %{dismiss: :cancel, challenge: %{type: :qr, value: "private"}})

    {:ok, abandoned_view} = Zaq.SignIn.view(abandoned, %{dismiss: :cancel})

    socket =
      DeviceSignInPolling.open(
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}},
        active_view,
        view_key: :view,
        dispatch: dispatch
      )

    assert DeviceSignInPolling.result(
             socket,
             make_ref(),
             make_ref(),
             {:ok, {dispatch, {:ok, active_view}}}
           ) == socket

    assert DeviceSignInPolling.result(
             socket,
             make_ref(),
             make_ref(),
             {:ok, {dispatch, {:ok, abandoned_view}}}
           ) == socket

    assert_receive {:DOWN, ^abandoned_monitor, :process, ^abandoned, :normal}, 1_000
    assert {:ok, _} = sign_in({:observe, active}, actor)

    timer = socket.private.sign_in_observer_timer.timer_ref
    closed = DeviceSignInPolling.dismiss(socket)
    assert closed.assigns.view == nil
    assert Process.read_timer(timer) == false
    assert_receive {:DOWN, ^active_monitor, :process, ^active, :normal}, 1_000
  end

  test "expiry and browser disconnect clean up without creating a connector", %{actor: actor} do
    count = Repo.aggregate(ChannelConfig, :count)

    for reason <- [:expiry, :browser] do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert {:ok, %{ref: session}} = sign_in({:begin, %{owner: owner}}, actor)
      assert_receive {:whatsapp_connected_config, options}
      monitor = Process.monitor(session)
      if reason == :expiry, do: send(session, :expire), else: send(owner, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
      send(owner, :stop)
      assert {:error, :not_connected} = Transport.resolve_conn(profile: options.profile)
    end

    assert Repo.aggregate(ChannelConfig, :count) == count
  end

  test "unprivileged callers and non-confidential calls cannot pair", %{actor: actor} do
    command = {:begin, %{owner: self()}}
    assert {:error, _} = sign_in(command, %{user_id: user_fixture().id})
    assert {:error, _} = sign_in(command, actor, false)
    assert {:error, _} = sign_in(command, nil)
  end

  defp qr(session, actor) do
    assert {:ok, %{status: "pending", challenge: %{type: :qr, value: qr}}} =
             sign_in({:observe, session}, actor)

    qr
  end

  defp account_id(session, actor) do
    assert {:ok, %{status: "confirm", confirmation: %{external_id: id}}} =
             sign_in({:observe, session}, actor)

    id
  end

  defp await_status(session, actor, status),
    do:
      eventually(fn -> sign_in({:observe, session}, actor) end,
        matches: &match?({:ok, %{status: ^status}}, &1),
        timeout: 1_000,
        label: "pairing status #{status}"
      )
end

defmodule Zaq.Channels.LinkedDevice.PairingApiTest do
  use Zaq.DataCase, async: false
  import Zaq.AccountsFixtures
  alias Zaq.Channels.Api
  alias Zaq.Event
  alias ZaqWeb.Live.BO.AI.BOActor

  defmodule ExampleAdapter do
    @moduledoc false
    use Jido.Chat.Adapter

    @impl true
    def channel_type, do: :example

    @impl true
    def transform_incoming(_), do: {:error, :unsupported}

    @impl true
    def send_message(_, _, _), do: {:error, :unsupported}

    @impl true
    def authenticate(request, owner_id, opts) do
      session = request[:session] || request.owner
      send(session, {:adapter_authentication, owner_id, request, opts})
      {:ok, %{phase: :pending, session: session}}
    end
  end

  defmodule FiveArgumentBridge do
    @moduledoc false
    def authenticate(provider, request, owner_id, actor, opts) do
      send(request.owner, {:bridge_authentication, provider, owner_id, actor, opts})
      {:ok, %{phase: :pending, session: request.owner}}
    end
  end

  defmodule UnauthenticatedBridge do
    @moduledoc false
  end

  defmodule ExampleConfig do
    @moduledoc false
    def get(:zaq, :channels, _default, opts),
      do: %{
        example: %{
          bridge: opts[:test_bridge] || Zaq.Channels.JidoChatBridge,
          adapter: opts[:test_adapter]
        }
      }
  end

  defmodule FailingRuntime do
    @moduledoc false
    def bridge_for(_), do: __MODULE__
    defdelegate fetch_channel_config(provider, id), to: Zaq.Channels.Bridge
    def sync_provider_runtime(_), do: {:error, :connection_start_failed}
  end

  test "retry propagates the actual runtime failure" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})

    event =
      Event.new(%{provider: :whatsapp, channel_config_id: config.id}, :channels,
        actor: %{user_id: admin.id},
        opts: [confidential: true, skip_permissions: true, bridge_module: FailingRuntime]
      )

    assert Api.handle_event(event, :sync_provider_runtime, nil).response ==
             {:error, :connection_start_failed}
  end

  test "a second adapter traverses the authorized Action and both bridges" do
    admin = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: admin.id}
    adapter = ExampleAdapter

    owner = self()
    owner_id = {"example", admin.id}
    begin_request = %{provider: :example, command: {:begin, %{owner: owner, owner_id: "forged"}}}

    assert {:ok, %{status: "pending", ref: ^owner} = first} =
             authenticate(begin_request, actor, adapter)

    assert_receive {:adapter_authentication, ^owner_id, %{op: :begin, owner: ^owner}, options}
    assert options[:context] == %Zaq.Events.TrustedContext{actor: actor, skip_permissions: true}
    refute Map.has_key?(first, :owner_id)
    refute Map.has_key?(first, :request)
    refute Map.has_key?(first, :callbacks)

    assert Keyword.keys(Keyword.take(options, [:sink_mfa])) == [:sink_mfa]

    assert {Zaq.Channels.JidoChatBridge, :from_listener, [%{provider: :example}, capability]} =
             options[:sink_mfa]

    assert is_reference(capability)

    assert {:ok, followup} =
             authenticate(
               %{
                 provider: :example,
                 command: {:confirm, first.ref, "account-7"}
               },
               actor,
               adapter
             )

    assert followup.ref == first.ref

    assert_receive {:adapter_authentication, ^owner_id,
                    %{op: :confirm, session: ^owner, account_id: "account-7"}, []}

    admin |> Ecto.Changeset.change(must_change_password: true) |> Repo.update!()

    assert {:ok, _} =
             authenticate(
               %{provider: :example, command: {:observe, first.ref}},
               actor,
               adapter
             )
  end

  test "an adapter without authentication reports unsupported through the same Action" do
    admin = super_admin_fixture(%{must_change_password: false})
    adapter = Jido.Chat.Telegram.Adapter

    assert {:error, :unsupported} =
             authenticate(
               %{provider: :example, command: {:begin, %{owner: self()}}},
               %{user_id: admin.id},
               adapter
             )
  end

  test "a five-argument-only bridge receives options through the authorized Action" do
    actor = %{user_id: super_admin_fixture(%{must_change_password: false}).id}
    owner = self()
    request = %{provider: :example, command: {:begin, %{owner: owner}}}

    assert {:ok, %{status: "pending", ref: ^owner}} =
             authenticate(request, actor, ExampleAdapter, test_bridge: FiveArgumentBridge)

    assert_receive {:bridge_authentication, :example, id, ^actor, opts}
    assert id == actor.user_id
    assert opts[:test_adapter] == ExampleAdapter
    assert opts[:test_bridge] == FiveArgumentBridge

    assert {:error, :unsupported} =
             authenticate(request, actor, ExampleAdapter, test_bridge: UnauthenticatedBridge)
  end

  test "raw pairing requests are rejected before reaching the adapter" do
    actor = %{user_id: super_admin_fixture(%{must_change_password: false}).id}

    assert {:error, :invalid_request} =
             authenticate(%{provider: :example, op: :begin, owner: self()}, actor, ExampleAdapter)

    refute_received {:adapter_authentication, _, _, _}
  end

  test "pairing status and retry deny nil, unprivileged and non-confidential callers" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})
    user = user_fixture()

    for action <- [:channel_ingress_status, :sync_provider_runtime],
        {actor, confidential} <- [
          {nil, true},
          {%{user_id: user.id}, true},
          {%{user_id: admin.id}, false}
        ] do
      assert {:error, :unauthorized} = call(config, action, actor, confidential)
    end
  end

  test "authorized status uses exact enabled connector and never trusts a supplied config" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})
    actor = BOActor.build(Repo.preload(admin, :role))

    assert {:ok, %{phase: :disconnected, qr: nil}} =
             call(config, :channel_ingress_status, actor, true)

    config |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert {:error, _} = call(config, :channel_ingress_status, actor, true)
    assert {:error, _} = call(config, :sync_provider_runtime, actor, true)
  end

  test "status and retry use session authority without reloading the operator" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})
    actor = BOActor.build(Repo.preload(admin, :role))

    assert {:ok, _} = call(config, :channel_ingress_status, actor, true)
    admin |> Ecto.Changeset.change(must_change_password: true) |> Repo.update!()

    {_, queries} =
      Zaq.QueryRecorder.capture(fn ->
        assert {:ok, _} = call(config, :channel_ingress_status, actor, true)
        assert :ok = call(config, :sync_provider_runtime, actor, true)
      end)

    refute Enum.any?(queries, &String.contains?(&1.query, "FROM \"users\""))
  end

  test "pairing commands cannot grant authorization through request fields" do
    actor = %{user_id: user_fixture().id}

    request = %{
      provider: :example,
      command: {:begin, %{owner: self()}},
      skip_permissions: true,
      actor: %{skip_permissions: true}
    }

    assert {:error, _} = authenticate(request, actor, ExampleAdapter, skip_permissions: false)
    refute_received {:adapter_authentication, _, _, _}
  end

  test "connector-scoped sync rejects invalid IDs instead of falling back to a supplied config" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})

    for id <- [nil, 0, -1, to_string(config.id)] do
      assert {:error, :unsupported} =
               call(
                 %{config | id: id},
                 :sync_provider_runtime,
                 BOActor.build(Repo.preload(admin, :role)),
                 true
               )
    end
  end

  defp call(config, action, actor, confidential) do
    Event.new(
      %{
        provider: :whatsapp,
        channel_config_id: config.id,
        config: %{config | provider: "telegram"}
      },
      :channels,
      actor: actor,
      opts: [
        action: action,
        confidential: confidential,
        skip_permissions: actor && actor[:skip_permissions] == true
      ]
    )
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end

  defp authenticate(request, actor, adapter, opts \\ []) do
    Event.new(request, :channels,
      actor: actor,
      opts:
        opts ++
          [
            action: :pair_linked_device,
            confidential: true,
            skip_permissions: true,
            config: ExampleConfig,
            test_adapter: adapter
          ]
    )
    |> Api.handle_event(:pair_linked_device, nil)
    |> Map.fetch!(:response)
  end

  defp connector, do: Zaq.WhatsAppFixtures.connector(%{name: "Pairing"})
end

defmodule Zaq.Channels.LinkedDevice.WhatsAppDeliveryTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{Api, Bridge, JidoChatBridge}
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event

  defmodule Adapter do
    @moduledoc false
    defdelegate connection_options(binding, opts), to: Jido.Chat.WhatsApp.Adapter
    defdelegate prepare_connection(opts), to: Jido.Chat.WhatsApp.Adapter
    defdelegate connection_identity(binding), to: Jido.Chat.WhatsApp.Adapter
    defdelegate provider_child_specs(opts), to: Jido.Chat.WhatsApp.Adapter

    def send_message(room, body, opts) do
      send(self(), {:sent, room, body, opts})
      {:ok, %{external_message_id: "sent-1"}}
    end

    def edit_message(room, id, body, opts) do
      send(self(), {:edited, room, id, body, opts})
      :ok
    end

    def start_typing(room, opts), do: notify({:typing, room, opts})
    def add_reaction(room, id, emoji, opts), do: notify({:reaction, room, id, emoji, opts})

    def remove_reaction(room, id, emoji, opts),
      do: notify({:remove_reaction, room, id, emoji, opts})

    def open_dm(id, opts) do
      send(self(), {:dm, id, opts})
      {:ok, id}
    end

    defp notify(message) do
      send(self(), message)
      :ok
    end
  end

  setup do
    previous = Application.fetch_env!(:zaq, :channels)
    Application.put_env(:zaq, :channels, put_in(previous, [:whatsapp, :adapter], Adapter))
    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    {:ok, first: connector("First"), second: connector("Second")}
  end

  test "selected second connector reaches send and edit, with canonical receipt", %{
    second: config
  } do
    outgoing = %Outgoing{
      provider: :whatsapp,
      channel_id: "peer@s.whatsapp.net",
      body: "answer",
      routing_context: %{channel_config_id: config.id}
    }

    assert {:ok, %{message_id: "sent-1"}} = dispatch(outgoing, :deliver_outgoing)
    assert_received {:sent, "peer@s.whatsapp.net", "answer", opts}
    assert opts[:profile] == JidoChatBridge.resolve_connection_details(config, %{}).profile

    assert {:ok, _} = dispatch(%{outgoing | metadata: %{message_id: "sent-1"}}, :deliver_outgoing)
    assert_received {:edited, _, "sent-1", "answer", edit_opts}
    assert edit_opts[:profile] == opts[:profile]
  end

  test "typing and other operations preserve the selected account", %{second: config} do
    details = Bridge.fetch_connection_details_for_config(config)

    assert :ok =
             dispatch(
               %{provider: :whatsapp, channel_id: "peer", channel_config_id: config.id},
               :send_typing
             )

    assert_received {:typing, "peer", opts}
    assert opts[:profile] == details.profile
    assert :ok = JidoChatBridge.add_reaction(:whatsapp, "peer", "msg", "👍", details)
    assert_received {:reaction, _, _, _, reaction_opts}
    assert reaction_opts[:profile] == details.profile
    assert :ok = JidoChatBridge.remove_reaction(:whatsapp, "peer", "msg", "👍", details)
    assert_received {:remove_reaction, _, _, _, remove_opts}
    assert remove_opts[:profile] == details.profile

    assert {:ok, "peer"} =
             dispatch(
               %{provider: :whatsapp, author_id: "peer", channel_config_id: config.id},
               :open_dm_channel
             )

    assert_received {:dm, "peer", dm_opts}
    assert dm_opts[:profile] == details.profile
  end

  test "ambiguous and missing selections never fall back to the first account" do
    assert {:error, _} =
             dispatch(
               %Outgoing{provider: :whatsapp, channel_id: "peer", body: "no"},
               :deliver_outgoing
             )

    assert {:error, _} =
             dispatch(
               %{provider: :whatsapp, channel_id: "peer", channel_config_id: -1},
               :send_typing
             )

    assert {:error, :missing_linked_device_profile} =
             JidoChatBridge.send_typing(:whatsapp, "peer", %{url: "", token: ""})

    refute_received {:sent, _, _, _}
    refute_received {:typing, _, _}
  end

  defp dispatch(request, action) do
    request
    |> Event.new(:channels, opts: [action: action])
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end

  defp connector(name), do: Zaq.WhatsAppFixtures.connector(%{name: name, enabled: true})
end

defmodule Zaq.Channels.LinkedDevice.WhatsAppFullFlowTest do
  @moduledoc """
  QR UI → real adapter decoder → bridge → NodeRouter → Engine admission →
  configured agent → model HTTP → real adapter send/edit → simulated recipient.
  Only the external WhatsApp service and model endpoint are simulated.
  """
  use ZaqWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures
  import Zaq.TestSupport.Eventually

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Repo
  alias Zaq.TestSupport.{ApplicationEnv, MultiAgentOpenAIStub, OpenAIStub, WhatsAppFlowAdapter}
  alias Zaq.TestSupport.WhatsAppFlowTransport, as: Transport

  @self_jid "15550001@s.whatsapp.net"
  @peer_jid "15550002@s.whatsapp.net"
  @answer "WhatsApp full-flow answer"
  @runtime_keys [
    :channels,
    :node_router,
    :chat_bridge_pipeline_module,
    :chat_bridge_node_router_module,
    :chat_bridge_accounts_module,
    :chat_bridge_permissions_module,
    :chat_bridge_supervisor_module,
    :chat_bridge_chat_module,
    :pipeline_hooks_module
  ]

  setup %{conn: conn} do
    Zaq.DataCase.isolate_event_registry()
    observer = self()
    ApplicationEnv.preserve(:zaq, @runtime_keys)
    Enum.each(@runtime_keys, &Application.delete_env(:zaq, &1))
    Application.put_env(:zaq, :node_router, Zaq.NodeRouter)

    Application.put_env(:zaq, :channels, %{
      whatsapp: %{
        bridge: JidoChatBridge,
        adapter: WhatsAppFlowAdapter,
        ingress_mode: :linked_device
      }
    })

    assert :ok = JidoChatBridge.start_runtime({:provider, :whatsapp}, [])
    start_supervised!({Transport, observer: observer})

    {server, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          if conn.request_path == "/v1/responses" do
            send(
              observer,
              {:whatsapp_model_input, MultiAgentOpenAIStub.latest_user_message(body)}
            )

            {200, MultiAgentOpenAIStub.text_sse(@answer, "gpt-4.1-mini")}
          else
            {404, %{error: "unexpected model route"}}
          end
        end,
        observer
      )

    start_supervised!(server)
    credential = ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "WhatsApp flow #{System.unique_integer([:positive])}",
        description: "",
        job: "Answer briefly.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{"stream" => false}
      })

    config = Zaq.WhatsAppFixtures.connector(%{name: "WhatsApp full flow", enabled: true})

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
        routing_mode: :agent,
        configured_agent_id: agent.id
      })

    {:ok, person} = People.create_person(%{full_name: "WhatsApp sender"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "whatsapp",
        channel_config_id: config.id,
        channel_identifier: @peer_jid,
        dm_channel_id: @peer_jid,
        weight: 0
      })

    admin = super_admin_fixture()
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})

    on_exit(fn ->
      ServerManager.stop_server(agent)
      JidoChatBridge.stop_runtime(config)
    end)

    assert :ok = JidoChatBridge.start_runtime(config)
    profile = JidoChatBridge.resolve_connection_details(config, %{}).profile
    %{conn: init_test_session(conn, %{user_id: admin.id}), config: config, profile: profile}
  end

  test "QR pairing and direct message reach the agent and the WhatsApp recipient", context do
    pair_from_ui(context)
    run_message(context, @peer_jid, [])
  end

  test "QR pairing and a group mention reach the agent and the group recipient", context do
    pair_from_ui(context)
    unaddressed = incoming_message("15550003@g.us", [])
    assert :ok = Transport.incoming(context.profile, unaddressed)

    assert eventually(fn -> Repo.get_by(Message, external_message_id: unaddressed.id) != nil end)

    run_message(context, "15550003@g.us", [@self_jid])

    captured = Repo.get_by!(Message, external_message_id: unaddressed.id)
    assert captured.role == "external"
    assert captured.conversation_id == nil
    refute Repo.get_by(ExecutionRecord, user_message_id: captured.id)
    refute_received {:whatsapp_model_input, _}
  end

  test "replayed history cannot start agent replies while live messages still work", context do
    pair_from_ui(context)

    for {room, mentions} <- [{@peer_jid, []}, {"15550003@g.us", [@self_jid]}] do
      message = incoming_message(room, mentions)

      payload =
        message
        |> Jido.Chat.WhatsApp.Message.to_payload(%{
          history: true,
          event: :history_sync,
          profile: context.profile
        })
        |> Map.put(:account_jids, [@self_jid])

      assert :ok = JidoChatBridge.from_listener(context.config, payload, [])
      refute Repo.get_by(Message, external_message_id: message.id)
    end

    refute_received {:whatsapp_model_input, _}
    assert Transport.mailbox() == %{}
    run_message(context, @peer_jid, [])
  end

  defp pair_from_ui(%{conn: conn, config: config, profile: profile}) do
    assert_receive {:whatsapp_connected_config, connection_config}
    assert connection_config.profile == profile
    assert connection_config.sync_history == false
    assert connection_config.sync_full_history == false
    assert {Jido.Chat.WhatsApp.Storage.Split, _} = connection_config.storage
    refute Map.has_key?(connection_config, :storage_root)
    await_pairing(config)

    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/whatsapp")
    view |> element("#ingress-status-dot-#{config.id}") |> render_click()
    render_async(view)

    assert has_element?(
             view,
             "#linked-device-pairing svg[aria-label='Device connection QR code']"
           )

    assert {:ok, %{phase: :pairing, qr: qr}} = JidoChatBridge.channel_ingress_status(config)
    assert :ok = Transport.scan(profile, qr)

    assert eventually(fn ->
             match?(
               {:ok, %{phase: :connected, qr: nil}},
               JidoChatBridge.channel_ingress_status(config)
             )
           end)

    view |> element("#linked-device-pairing button", "Close") |> render_click()
    view |> element("#ingress-status-dot-#{config.id}") |> render_click()
    render_async(view)
    assert has_element?(view, "#linked-device-pairing", "Linked device connected")
    refute has_element?(view, "#linked-device-pairing svg")
  end

  defp await_pairing(config) do
    {:ok, state} = Zaq.Channels.Supervisor.lookup_state_pid("whatsapp_#{config.id}")
    :erlang.trace(state, true, [:receive])

    try do
      # Transport startup precedes the ordered lifecycle callback. Wait for the
      # QR event, including a retry while the generic supervisor registers state.
      unless match?({:ok, %{phase: :pairing}}, JidoChatBridge.channel_ingress_status(config)) do
        assert_receive {:trace, ^state, :receive,
                        {:"$gen_call", _,
                         {:process_listener_payload, _,
                          %Jido.Chat.EventEnvelope{payload: %{metadata: %{status: :pairing}}}, _}}},
                       1_000
      end

      assert {:ok, %{phase: :pairing}} = JidoChatBridge.channel_ingress_status(config)
    after
      :erlang.trace(state, false, [:receive])
    end
  end

  defp run_message(%{profile: profile, config: config}, room, mentions) do
    message = incoming_message(room, mentions)

    assert :ok = Transport.incoming(profile, message)
    assert_receive {:whatsapp_model_input, model_input}, 10_000
    assert model_input =~ message.content
    assert_receive {:whatsapp_recipient_received, ^profile, ^room, reply_id, @answer}, 10_000
    assert Transport.mailbox()[{profile, room, reply_id}] == @answer

    assert eventually(fn ->
             Repo.exists?(
               from(e in ExecutionRecord,
                 join: m in Message,
                 on: e.user_message_id == m.id,
                 where: e.status == "completed" and m.external_message_id == ^message.id
               )
             )
           end)

    incoming = Repo.get_by!(Message, external_message_id: message.id, source_provider: "whatsapp")
    assert incoming.role == "user"
    assert is_binary(incoming.conversation_id)

    assert Conversations.get_conversation!(incoming.conversation_id).channel_config_id ==
             config.id

    execution = Repo.get_by!(ExecutionRecord, user_message_id: incoming.id)
    answer = Repo.get!(Message, execution.public_answer_message_id)
    assert answer.conversation_id == incoming.conversation_id
    assert answer.role == "assistant"
    assert answer.content == @answer
  end

  defp incoming_message(room, mentions) do
    id = Ecto.UUID.generate()

    %Amarula.Msg{
      id: id,
      channel: Amarula.Address.parse(room),
      from: Amarula.Address.parse(@peer_jid),
      to: Amarula.Address.parse(@self_jid),
      mentions: Enum.map(mentions, &Amarula.Address.parse/1),
      type: :text,
      content: "WhatsApp question #{id}",
      timestamp: System.system_time(:second),
      raw: %{}
    }
  end
end
