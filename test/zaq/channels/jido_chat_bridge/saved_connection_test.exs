defmodule Zaq.Channels.JidoChatBridge.SavedConnectionTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures
  import Zaq.WhatsAppFixtures, only: [connector: 0, private_sink: 1, authentication_sink: 0]

  alias Ecto.Adapters.SQL.Sandbox
  alias Jido.Chat.Authentication.Request, as: PairingRequest
  alias Jido.Chat.Storage.Request
  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Storage.Split
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Engine.ChannelConfig

  test "persisted history options reach saved and authenticated listener startup independently" do
    for history <- [false, true], full <- [false, true] do
      assert {:ok, config} =
               ChannelConfig.create(
                 %{
                   name: Ecto.UUID.generate(),
                   provider: "whatsapp",
                   kind: "retrieval",
                   settings: %{
                     "jido_chat" => %{
                       "ingress" => %{"sync_history" => history, "sync_full_history" => full}
                     }
                   }
                 },
                 adapter_authentication: true
               )

      config = Repo.get!(ChannelConfig, config.id)
      assert {:ok, {_state, [saved_spec]}} = JidoChatBridge.build_runtime_specs(config)
      {Jido.Chat.WhatsApp.ConnectionWorker, :start_link, [saved_opts]} = saved_spec.start
      options = Keyword.fetch!(saved_opts, :config)
      assert options.sync_history == history
      assert options.sync_full_history == full

      # The authenticated handoff may carry different transport defaults. Persisted
      # connector settings still select the history behavior for this listener.
      handoff = %{options | sync_history: not history, sync_full_history: not full}

      for runtime <- [config, Map.put(config, :authentication_connection_options, handoff)] do
        assert {_, [spec]} =
                 JidoChatBridge.runtime_specs(runtime, "history_#{config.id}", channel_ids: :all)

        {Jido.Chat.WhatsApp.ConnectionWorker, :start_link, [opts]} = spec.start
        assert opts[:config].sync_history == history
        assert opts[:config].sync_full_history == full
        assert opts[:config].profile == options.profile
        assert {Split, listener_storage} = opts[:config].storage
        {Split, saved_storage} = options.storage
        assert listener_storage[:context] == saved_storage[:context]
        assert listener_storage[:scope] == saved_storage[:scope]
      end
    end
  end

  test "adapter validates saved history options while generic persistence remains transport agnostic" do
    for flag <- ~w(sync_history sync_full_history), value <- [nil, "false", 0, []] do
      assert {:ok, config} =
               ChannelConfig.create(
                 %{
                   name: Ecto.UUID.generate(),
                   provider: "whatsapp",
                   kind: "retrieval",
                   settings: %{"jido_chat" => %{"ingress" => %{flag => value}}}
                 },
                 adapter_authentication: true
               )

      assert {:error, :invalid_history_options} =
               JidoChatBridge.build_runtime_specs(config)
    end
  end

  test "invalid and disabled connectors cannot yield saved options" do
    config = connector()
    assert {:ok, {_state, [_listener]}} = JidoChatBridge.build_runtime_specs(config)
    Repo.update!(Ecto.Changeset.change(config, enabled: false))

    assert {:error, :connector_unavailable} =
             JidoChatBridge.build_runtime_specs(config)
  end

  property "different durable bindings yield distinct stable adapter profiles" do
    check all(first <- positive_integer(), offset <- positive_integer()) do
      second = first + offset
      first_binding = %{channel_config_id: first, credential_id: 1}
      second_binding = %{channel_config_id: second, credential_id: 1}
      {:ok, first_profile} = Adapter.connection_identity(first_binding)
      {:ok, second_profile} = Adapter.connection_identity(second_binding)

      refute first_profile == second_profile
      assert {:ok, ^first_profile} = Adapter.connection_identity(first_binding)
    end
  end

  test "storage requests bypass listener registration and public chat ingress rejects them" do
    config = connector()
    {_, _, [context, _]} = private_sink(Map.put(config, :token, "private-token"))
    assert context == %{id: config.id, provider: config.provider}
    event = %Request{binding: nil, request: %{op: :bind}}
    assert {:error, :invalid_storage_request} = JidoChatBridge.from_listener(config, event, [])

    assert {:error, :invalid_storage_request} =
             JidoChatBridge.from_listener(config, nil, event, [])

    {module, function, args} = private_sink(config)
    assert {:ok, binding} = apply(module, function, args ++ [event, [bridge_id: "absent_bridge"]])
    assert binding.channel_config_id == config.id
    assert {:ok, options} = Adapter.prepare_connection(sink_mfa: {module, function, args})
    {Split, opts} = options.storage
    state = Split.new(opts)
    assert :ok = Split.put(state, options.profile, :creds, :self, %{paired: true})
    assert {:ok, %{paired: true}} = Split.get(state, options.profile, :creds, :self)
  end

  test "trusted sinks reject another connector's binding and another provider" do
    first = connector()
    second = connector()
    sink = private_sink(first)
    assert {:ok, binding} = Request.call(sink, nil, %{op: :bind})

    assert {:error, :invalid_binding} =
             Request.call(private_sink(second), binding, %{
               op: :list_keys,
               namespace: "creds"
             })

    assert {:error, :invalid_provider} =
             JidoChatBridge.from_listener(
               %{provider: "telegram"},
               make_ref(),
               %Request{binding: binding, request: %{op: :list_keys, namespace: "creds"}},
               []
             )
  end

  test "a storage callback completes while the bridge State itself is handling work" do
    config = connector()

    assert {:ok, prepared} =
             Jido.Chat.Adapter.prepare_connection(Adapter,
               sink_mfa: private_sink(config)
             )

    options = Keyword.fetch!(prepared, :ingress)
    {Split, opts} = options.storage
    storage = Split.new(opts)

    pid =
      start_supervised!(
        {State,
         bridge_id: "storage_reentry_#{config.id}",
         config: ChannelConfig.to_runtime_config(config),
         provider: :whatsapp}
      )

    Sandbox.allow(Repo, self(), pid)

    # Run on the real State process, as an outbound adapter operation does.
    # Routing the storage request back through State would wait on itself.
    :sys.replace_state(pid, fn current ->
      assert :ok = Split.put(storage, options.profile, :creds, :self, %{paired: true})
      current
    end)

    assert {:ok, %{paired: true}} = Split.get(storage, options.profile, :creds, :self)
  end

  test "one trusted sink persists idempotently and makes credentials available to storage requests" do
    admin = super_admin_fixture(%{must_change_password: false})
    context = %Zaq.Events.TrustedContext{actor: %{user_id: admin.id}, skip_permissions: true}
    sink = authentication_sink()
    credentials = Split.encode_records(%{{:creds, :self} => %{paired: true}})

    request = %{
      op: :persist,
      attempt_id: Ecto.UUID.generate(),
      account: %{external_id: "+15550001", display_name: "Account"},
      credentials: credentials
    }

    assert {:ok, saved} = PairingRequest.call(sink, context, request)
    assert {:ok, repeated} = PairingRequest.call(sink, context, request)
    assert saved.receipt == repeated.receipt
    assert saved.binding == repeated.binding
    assert saved.runtime.provider == "whatsapp"

    %{profile: profile, storage: {Split, opts}} =
      Adapter.connection_options(saved.binding, sink_mfa: sink)

    assert {:ok, %{paired: true}} = Split.get(Split.new(opts), profile, :creds, :self)

    # Activation is a separate request. A provider mismatch leaves the save intact.
    mismatched = %{runtime: %{saved.runtime | provider: "telegram"}, connection_options: %{}}

    assert {:error, :invalid_connector} =
             PairingRequest.call(sink, context, %{op: :start, runtime: mismatched})

    assert {:ok, %{paired: true}} = Split.get(Split.new(opts), profile, :creds, :self)
  end

  test "persistence and activation require trusted session authority and actor identity" do
    admin = super_admin_fixture(%{must_change_password: false})
    actor = %{user_id: admin.id}
    sink = authentication_sink()

    for context <- [
          nil,
          actor,
          %Zaq.Events.TrustedContext{actor: actor},
          %Zaq.Events.TrustedContext{skip_permissions: true}
        ],
        request <- [%{op: :persist}, %{op: :start, runtime: %{}}] do
      assert {:error, :unauthorized} = PairingRequest.call(sink, context, request)
    end
  end

  test "public ingress and malformed private envelopes cannot enter pairing or message routing" do
    config = %{provider: :whatsapp}
    event = %PairingRequest{context: %{user_id: 42}, request: %{op: :persist}}
    assert {:error, :invalid_pairing_request} = JidoChatBridge.from_listener(config, event, [])

    assert {:error, :invalid_pairing_request} =
             JidoChatBridge.from_listener(config, nil, event, [])

    assert {:error, :invalid_pairing_request} =
             JidoChatBridge.from_listener(config, make_ref(), %{event | version: 2}, [])

    assert {:error, :invalid_pairing_request} =
             JidoChatBridge.from_listener(
               config,
               make_ref(),
               %{event | request: %{op: :unknown}},
               []
             )
  end

  test "authorized activation rejects malformed handoffs without starting a runtime" do
    admin = super_admin_fixture(%{must_change_password: false})
    config = connector()
    sink = private_sink(config)

    for runtime <- [
          nil,
          %{},
          %{runtime: nil, connection_options: %{}},
          %{runtime: config, connection_options: []}
        ] do
      assert {:error, :invalid_connector} =
               PairingRequest.call(
                 sink,
                 %Zaq.Events.TrustedContext{actor: %{user_id: admin.id}, skip_permissions: true},
                 %{op: :start, runtime: runtime}
               )
    end
  end

  test "activation rechecks saved eligibility after the handoff was prepared" do
    admin = super_admin_fixture(%{must_change_password: false})

    for change <- [
          %{enabled: false},
          %{enabled: false, archived_at: DateTime.utc_now() |> DateTime.truncate(:second)}
        ] do
      config = connector()
      options = JidoChatBridge.resolve_connection_details(config, %{})
      config = Repo.get!(ChannelConfig, config.id)
      sink = private_sink(config)
      config |> Ecto.Changeset.change(change) |> Repo.update!()

      assert {:error, :connector_unavailable} =
               PairingRequest.call(
                 sink,
                 %Zaq.Events.TrustedContext{actor: %{user_id: admin.id}, skip_permissions: true},
                 %{
                   op: :start,
                   runtime: %{runtime: config, connection_options: options}
                 }
               )
    end
  end
end
