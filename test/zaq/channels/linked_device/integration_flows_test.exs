defmodule Zaq.Channels.LinkedDevice.OnboardingTest do
  use Zaq.DataCase, async: false
  import Zaq.AccountsFixtures
  alias Jido.Chat.WhatsApp.ConnectionWorker
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.{Event, NodeRouter}
  alias Zaq.TestSupport.WhatsAppFlowAdapter
  alias Zaq.TestSupport.WhatsAppFlowTransport, as: Transport

  setup do
    previous = Application.fetch_env!(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      whatsapp: %{
        bridge: JidoChatBridge,
        adapter: WhatsAppFlowAdapter,
        ingress_mode: :linked_device
      }
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    assert :ok = JidoChatBridge.start_runtime({:provider, :whatsapp}, [])
    start_supervised!({Transport, observer: self()})
    %{actor: %{user_id: super_admin_fixture(%{must_change_password: false}).id}}
  end

  test "scan creates no connector; confirmation saves and restores the session once", %{
    actor: actor
  } do
    count = Repo.aggregate(ChannelConfig, :count)
    assert {:ok, %{session: session}} = call(%{op: :begin, owner: self()}, actor)

    assert Enum.any?(DynamicSupervisor.which_children(Zaq.Channels.BridgeSupervisor), fn
             {_, ^session, :worker, _} -> true
             _ -> false
           end)

    on_exit(fn -> call(%{op: :cancel, session: session}, actor) end)
    assert_receive {:whatsapp_connected_config, options}
    assert Repo.aggregate(ChannelConfig, :count) == count

    assert {:error, :identity_not_ready} =
             call(%{op: :confirm, session: session, account_id: "+15550001"}, actor)

    qr = qr(session, actor)
    assert :ok = Transport.scan(options.profile, qr)
    temporary_scope = Amarula.Storage.scope(options.storage)

    assert :ok =
             Amarula.Storage.put(temporary_scope, options.profile, :session, "peer", "ratchet")

    assert :ok =
             Amarula.Storage.put(temporary_scope, options.profile, :sender_key, "group", "key")

    assert await_phase(session, actor, :authenticated)
    account_id = account_id(session, actor)
    assert Repo.aggregate(ChannelConfig, :count) == count

    assert {:ok, %{receipt: saved, runtime_pending: false}} =
             call(%{op: :confirm, session: session, account_id: account_id}, actor)

    assert saved.name == "Support account"
    config = Repo.get!(ChannelConfig, saved.id)
    on_exit(fn -> JidoChatBridge.stop_runtime(config) end)

    assert {:ok, %{receipt: ^saved, runtime_pending: false}} =
             call(%{op: :confirm, session: session, account_id: account_id}, actor)

    assert Repo.aggregate(ChannelConfig, :count) == count + 1
    assert_receive {:whatsapp_connected_config, restored}
    refute restored.sync_history
    refute restored.sync_full_history
    assert {:ok, restored.profile} == JidoChatBridge.connection_profile(config)
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
               Connect.credential_document(%{
                 op: :list_keys,
                 binding: binding,
                 namespace: namespace
               })
    end

    assert {:ok, conn} = Transport.resolve_conn(profile: restored.profile)
    assert Agent.get(conn, & &1.paired?)
    assert config.settings["account"]["external_id"] == "+15550001"
  end

  test "confirmation rejects an account changed since it was displayed", %{actor: actor} do
    assert {:ok, %{session: session}} = call(%{op: :begin, owner: self()}, actor)
    assert_receive {:whatsapp_connected_config, options}
    qr = qr(session, actor)
    :ok = Transport.scan(options.profile, qr)
    assert await_phase(session, actor, :authenticated)
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

    assert {:error, :identity_changed} =
             call(%{op: :confirm, session: session, account_id: displayed_account_id}, actor)

    assert {:ok, %{phase: :cancelled}} = call(%{op: :cancel, session: session}, actor)
  end

  test "a RAM seed failure retains saved pairing and reports connection pending", %{actor: actor} do
    assert {:ok, %{session: session}} = call(%{op: :begin, owner: self()}, actor)
    on_exit(fn -> call(%{op: :cancel, session: session}, actor) end)
    assert_receive {:whatsapp_connected_config, options}
    qr = qr(session, actor)
    assert :ok = Transport.scan(options.profile, qr)
    assert await_phase(session, actor, :authenticated)
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

    assert {:ok, %{receipt: saved, runtime_pending: true}} =
             call(%{op: :confirm, session: session, account_id: account_id}, actor)

    assert {:ok, %{receipt: ^saved, runtime_pending: true}} =
             call(%{op: :confirm, session: session, account_id: account_id}, actor)

    config = Repo.get!(ChannelConfig, saved.id)
    on_exit(fn -> JidoChatBridge.stop_runtime(config) end)
    refute_received {:whatsapp_connected_config, _}

    assert :ok = JidoChatBridge.start_runtime(config)
    assert_receive {:whatsapp_connected_config, restored}
    scope = Amarula.Storage.scope(restored.storage)
    assert {:ok, %{paired: true}} = Amarula.Storage.get(scope, restored.profile, :creds, :self)
    assert :error = Amarula.Storage.get(scope, restored.profile, :session, "peer")
  end

  defp identity_ready?(worker, attempts \\ 100)
  defp identity_ready?(_, 0), do: false

  defp identity_ready?(worker, attempts) do
    case ConnectionWorker.status(worker) do
      %{identity: %{phone_number: "+15550002"}} ->
        true

      _ ->
        Process.sleep(10)
        identity_ready?(worker, attempts - 1)
    end
  end

  test "owner scoping and cancellation remove provisional sessions", %{actor: actor} do
    assert {:ok, %{session: session}} = call(%{op: :begin, owner: self()}, actor)
    assert_receive {:whatsapp_connected_config, options}
    other = %{user_id: super_admin_fixture(%{must_change_password: false}).id}
    assert {:error, :unauthorized} = call(%{op: :status, session: session}, other)
    assert {:ok, %{phase: :cancelled}} = call(%{op: :cancel, session: session}, actor)
    refute Process.alive?(session)
    assert {:error, :not_connected} = Transport.resolve_conn(profile: options.profile)
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

      assert {:ok, %{session: session}} = call(%{op: :begin, owner: owner}, actor)
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
    request = %{op: :begin, owner: self()}
    assert {:error, _} = call(request, %{user_id: user_fixture().id})
    assert {:error, _} = call(request, actor, false)
    assert {:error, _} = call(request, nil)
  end

  defp call(request, actor, confidential \\ true) do
    Event.new(Map.put_new(request, :provider, :whatsapp), :channels,
      actor: actor,
      opts: [action: :pair_linked_device, confidential: confidential]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  defp qr(session, actor) do
    assert {:ok, %{phase: :challenge, challenge: %{type: :qr, value: qr}}} =
             call(%{op: :status, session: session}, actor)

    qr
  end

  defp account_id(session, actor) do
    assert {:ok, %{phase: :authenticated, account: %{external_id: id}}} =
             call(%{op: :status, session: session}, actor)

    id
  end

  defp await_phase(session, actor, phase, attempts \\ 100)
  defp await_phase(_, _, _, 0), do: false

  defp await_phase(session, actor, phase, attempts) do
    case call(%{op: :status, session: session}, actor) do
      {:ok, %{phase: ^phase}} ->
        true

      _ ->
        Process.sleep(10)
        await_phase(session, actor, phase, attempts - 1)
    end
  end
end

defmodule Zaq.Channels.LinkedDevice.PairingApiTest do
  use Zaq.DataCase, async: false
  import Zaq.AccountsFixtures
  alias Zaq.Channels.Api
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Event

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
      {:ok,
       %{
         phase: :pending,
         session: request[:session] || self(),
         owner_id: owner_id,
         request: request,
         callbacks: Keyword.take(opts, [:sink_mfa])
       }}
    end
  end

  defmodule ExampleConfig do
    @moduledoc false
    def get(:zaq, :channels, _default, opts),
      do: %{example: %{bridge: Zaq.Channels.JidoChatBridge, adapter: opts[:test_adapter]}}
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
        opts: [confidential: true, bridge_module: FailingRuntime]
      )

    assert Api.handle_event(event, :channel_retry_linked_device, nil).response ==
             {:error, :connection_start_failed}
  end

  test "a second adapter traverses the authorized Action and both bridges" do
    admin = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: admin.id}
    adapter = ExampleAdapter

    begin_request = %{provider: :example, op: :begin, owner: self()}
    assert {:ok, first} = authenticate(begin_request, actor, adapter)
    assert first.owner_id == {"example", admin.id}
    assert first.request == begin_request

    assert Keyword.keys(first.callbacks) == [:sink_mfa]

    assert {Zaq.Channels.JidoChatBridge, :from_listener, [%{provider: :example}, capability]} =
             first.callbacks[:sink_mfa]

    assert is_reference(capability)

    assert {:ok, followup} =
             authenticate(
               %{
                 provider: :example,
                 op: :confirm,
                 session: first.session,
                 account_id: "account-7"
               },
               actor,
               adapter
             )

    assert followup.owner_id == first.owner_id
    assert followup.request.account_id == "account-7"
    assert followup.callbacks == []

    admin |> Ecto.Changeset.change(must_change_password: true) |> Repo.update!()

    assert {:error, %{details: %{reason: :unauthorized}}} =
             authenticate(
               %{provider: :example, op: :status, session: first.session},
               actor,
               adapter
             )
  end

  test "a legacy adapter reports unsupported through the same Action" do
    admin = super_admin_fixture(%{must_change_password: false})
    adapter = Jido.Chat.Telegram.Adapter

    assert {:error, :unsupported} =
             authenticate(
               %{provider: :example, op: :begin, owner: self()},
               %{user_id: admin.id},
               adapter
             )
  end

  test "pairing status and retry deny nil, unprivileged and non-confidential callers" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})
    user = user_fixture()

    for action <- [:channel_ingress_status, :channel_retry_linked_device],
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

    assert {:ok, %{phase: :disconnected, qr: nil}} =
             call(config, :channel_ingress_status, %{user_id: admin.id}, true)

    config |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert {:error, _} = call(config, :channel_ingress_status, %{user_id: admin.id}, true)
    assert {:error, _} = call(config, :channel_retry_linked_device, %{user_id: admin.id}, true)
  end

  test "status and retry revalidate an operator whose password must now change" do
    config = connector()
    admin = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: admin.id}

    assert {:ok, _} = call(config, :channel_ingress_status, actor, true)
    admin |> Ecto.Changeset.change(must_change_password: true) |> Repo.update!()

    for action <- [:channel_ingress_status, :channel_retry_linked_device] do
      assert {:error, :unauthorized} = call(config, action, actor, true)
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
      opts: [action: action, confidential: confidential]
    )
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end

  defp authenticate(request, actor, adapter) do
    Event.new(request, :channels,
      actor: actor,
      opts: [
        action: :pair_linked_device,
        confidential: true,
        config: ExampleConfig,
        test_adapter: adapter
      ]
    )
    |> Api.handle_event(:pair_linked_device, nil)
    |> Map.fetch!(:response)
  end

  defp connector do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{name: "Pairing", provider: "whatsapp", kind: "retrieval"})
    |> Repo.insert!()
  end
end

defmodule Zaq.Channels.LinkedDevice.WhatsAppDeliveryTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{Api, Bridge, JidoChatBridge}
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event

  defmodule Adapter do
    @moduledoc false
    defdelegate connection_options(binding, opts), to: Jido.Chat.WhatsApp.Adapter
    defdelegate prepare_connection(opts), to: Jido.Chat.WhatsApp.Adapter
    defdelegate connection_profile(binding), to: Jido.Chat.WhatsApp.Adapter
    defdelegate storage_runtime_spec(opts), to: Jido.Chat.WhatsApp.Adapter

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
    assert {:ok, opts[:profile]} == JidoChatBridge.connection_profile(config)

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

  defp connector(name) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: name,
      provider: "whatsapp",
      kind: "retrieval",
      enabled: true
    })
    |> Repo.insert!()
  end
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

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Repo
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub, WhatsAppFlowAdapter}
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
    previous = Map.new(@runtime_keys, &{&1, Application.fetch_env(:zaq, &1)})
    Enum.each(@runtime_keys, &Application.delete_env(:zaq, &1))
    Application.put_env(:zaq, :node_router, Zaq.NodeRouter)

    Application.put_env(:zaq, :channels, %{
      whatsapp: %{
        bridge: JidoChatBridge,
        adapter: WhatsAppFlowAdapter,
        ingress_mode: :linked_device
      }
    })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:zaq, key, value)
        {key, :error} -> Application.delete_env(:zaq, key)
      end)
    end)

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

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "WhatsApp full flow",
        provider: "whatsapp",
        kind: "retrieval",
        enabled: true
      })
      |> Repo.insert!()

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
    {:ok, profile} = JidoChatBridge.connection_profile(config)
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

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
