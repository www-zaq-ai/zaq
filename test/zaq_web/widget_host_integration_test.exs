defmodule ZaqWeb.WidgetHostIntegrationTest do
  use ZaqWeb.ConnCase, async: false
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias WebWidget.Integration.{BindingStore, SignedIdentity}
  alias WebWidget.Runtime, as: WidgetRuntime
  alias Zaq.Accounts.People
  alias Zaq.Channels.WebBridge
  alias Zaq.CommunicationFixtures
  alias Zaq.ConnectorConfig.WidgetSettings
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
  alias Zaq.System, as: ZaqSystem

  setup do
    previous_roles = System.get_env("ROLES")
    previous_channels = Application.get_env(:zaq, :channels)
    System.put_env("ROLES", "all")

    Application.put_env(
      :zaq,
      :channels,
      Map.put(previous_channels, :web_widget, %{
        bridge: WebBridge,
        adapter: WebWidget.HostAdapter
      })
    )

    # Each scenario starts with its own package restart budget and boot options.
    # Crash tests must not inherit earlier tests' restart history.
    replace_infrastructure(pubsub_server: Zaq.PubSub, session: [partitioned: false])

    config = %{
      id: System.unique_integer([:positive]),
      name: "Real adapter",
      provider: "web_widget",
      enabled: true,
      token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      settings:
        WidgetSettings.defaults()
        |> Map.put("same_site", "Lax")
        |> Map.put("allowed_domains", ["https://parent.example.test"])
    }

    assert :ok = WebBridge.start_runtime(config)

    on_exit(fn ->
      WebBridge.stop_runtime(config)
      Application.put_env(:zaq, :channels, previous_channels)
      replace_infrastructure(pubsub_server: Zaq.PubSub)

      if previous_roles,
        do: System.put_env("ROLES", previous_roles),
        else: System.delete_env("ROLES")
    end)

    %{widget: config}
  end

  test "widget page and bootstrap use scoped transport without fetching or rewriting BO session",
       %{conn: conn, widget: widget} do
    page = get(conn, "/channels/widget/#{widget.id}")
    assert html_response(page, 200) =~ "/channels/widget/#{widget.id}/live"
    assert page.resp_cookies == %{}

    session = get(build_conn(), "/channels/widget/#{widget.id}/session")
    assert %{"csrf_token" => token} = json_response(session, 200)
    assert is_binary(token)
    assert session.resp_cookies["_web_widget_session"].path == "/channels/widget/#{widget.id}"
    assert session.resp_cookies["_web_widget_session"].same_site == "Lax"
    assert session.resp_cookies["_web_widget_session"].http_only
    refute Map.has_key?(session.resp_cookies, "_zaq_key")

    verified = session |> recycle() |> get("/channels/widget/#{widget.id}/session?verify=1")
    assert %{"csrf_token" => verified_token} = json_response(verified, 200)
    state = get_session(session, "_csrf_token")
    assert get_session(verified, "_csrf_token") == state
    assert Plug.CSRFProtection.valid_state_and_csrf_token?(state, token)
    assert Plug.CSRFProtection.valid_state_and_csrf_token?(state, verified_token)
    assert verified.resp_cookies == %{}

    Zaq.AccountsFixtures.admin_fixture(%{must_change_password: false})
    bo = get(build_conn(), "/bo/login")
    assert html_response(bo, 200) =~ "html"
    assert bo.resp_cookies["_zaq_key"].same_site == "Lax"
    refute Map.has_key?(bo.resp_cookies, "_web_widget_session")
  end

  test "widget and control routes require a channels role, not BO authentication", %{
    widget: widget
  } do
    System.put_env("ROLES", "bo")
    assert get(build_conn(), "/channels/widget/#{widget.id}").status == 404
    assert post(build_conn(), "/channels/widget-api/#{widget.id}/disconnect", %{}).status == 404
    System.put_env("ROLES", "channels")
    assert get(build_conn(), "/channels/widget/#{widget.id}").status == 200
    assert post(build_conn(), "/channels/widget-api/#{widget.id}/disconnect", %{}).status == 401
  end

  test "runtime registration without a listener never becomes healthy", %{widget: widget} do
    assert {:ok, %{status: :error, reason: :transport_not_listening}} =
             WebBridge.channel_ingress_status(widget)
  end

  test "generated installation and bundled assets share the trusted channels scope", %{
    widget: widget
  } do
    assert {:ok, snippet} =
             WebWidget.HostAdapter.installation(widget.id, "https://zaq.example.test",
               scope: "/channels"
             )

    assert snippet =~ "https://zaq.example.test/channels/web_widget/assets/embed.js"
    assert snippet =~ "https://zaq.example.test/channels/widget/#{widget.id}"

    for asset <- ["embed.js", "app.js", "app.css"] do
      response = get(build_conn(), "/channels/web_widget/assets/#{asset}")
      assert response.status == 200
      assert byte_size(response.resp_body) > 0
    end

    assert Phoenix.Router.route_info(ZaqWeb.Router, "GET", "/widget/#{widget.id}", "localhost") ==
             :error

    assert Phoenix.Router.route_info(
             ZaqWeb.Router,
             "GET",
             "/web_widget/assets/embed.js",
             "localhost"
           ) == :error

    assert Phoenix.Router.route_info(
             ZaqWeb.Router,
             "POST",
             "/widget-api/#{widget.id}/disconnect",
             "localhost"
           ) == :error
  end

  test "offline installation uses the same trusted mount when package is stopped", %{
    widget: widget
  } do
    assert :ok =
             DynamicSupervisor.terminate_child(
               Zaq.Channels.BridgeSupervisor,
               Process.whereis(WebWidget.Supervisor)
             )

    try do
      assert {:ok, snippet} =
               WebBridge.installation(
                 %{op: :installation, config: widget, base_url: "https://zaq.example.test"},
                 []
               )

      assert snippet =~ "/channels/web_widget/assets/embed.js"
      assert snippet =~ "/channels/widget/#{widget.id}"
    after
      replace_infrastructure(pubsub_server: Zaq.PubSub, session: [partitioned: false])
    end
  end

  test "Channels owns shared infrastructure before connector bootstrap", %{widget: widget} do
    children = DynamicSupervisor.which_children(Zaq.Channels.BridgeSupervisor)

    assert {_, infrastructure, :supervisor, [WebWidget.Supervisor]} =
             Enum.find(children, fn {_, _, _, modules} -> modules == [WebWidget.Supervisor] end)

    assert infrastructure == Process.whereis(WebWidget.Supervisor)

    assert {:ok, %{state_pid: connector, listener_pids: []}} =
             Zaq.Channels.Supervisor.lookup_runtime("web_widget_#{widget.id}")

    assert {_, ^connector, :supervisor, _} =
             Enum.find(children, fn {_, pid, _, _} -> pid == connector end)

    assert {:ok, %{checks: checks}} = WebBridge.channel_ingress_status(widget)
    assert checks.delivery == %{status: :ready, reason: nil}
    assert checks.authentication == %{status: :ready, reason: nil}
    assert {:ok, identity_proof} = proof(widget)

    assert {:ok, _} =
             WidgetRuntime.authenticate(to_string(widget.id), identity_proof, "owned-runtime")
  end

  test "installed v2 adapter acknowledges no-answer submissions without a pending assistant", %{
    widget: widget
  } do
    alias WebWidget.Integration.Chat
    alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    {:ok, config} =
      %ChannelConfig{id: widget.id}
      |> ChannelConfig.changeset(%{
        name: widget.name,
        provider: "web_widget",
        kind: "retrieval",
        enabled: true
      })
      |> Zaq.Repo.insert()

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{routing_mode: :none})

    {:ok, identity} = proof(widget)

    assert {:ok, chat} =
             Chat.open(
               to_string(widget.id),
               %{"identity_token" => identity},
               Ecto.UUID.generate()
             )

    try do
      assert {:ok, first} = Chat.submit(chat, "Informational message")
      assert is_binary(first.conversation_id)
      assert first.pending_submission == nil
      assert first.state.pending_reply == nil
      assert first.streams == %{}

      assert {:ok, second} = Chat.submit(first, "Another informational message")
      assert second.conversation_id == first.conversation_id
      assert second.pending_submission == nil
      assert second.state.pending_reply == nil
      assert second.streams == %{}

      assert Enum.map(second.state.messages, & &1.content) == [
               "Informational message",
               "Another informational message"
             ]

      assert_receive {:web_response, "response.user_message",
                      %{
                        type: :user_message,
                        payload: %{user_message: %{content: "Informational message"}}
                      }}

      assert_receive {:web_response, "response.user_message",
                      %{
                        type: :user_message,
                        payload: %{user_message: %{content: "Another informational message"}}
                      }}

      refute second.state.typing
      refute_receive {:web_response, _, _}
    after
      Chat.close(chat)
    end
  end

  test "a fresh authenticated widget page receives an answer started before reload", %{
    widget: widget
  } do
    alias WebWidget.Integration.Chat
    alias Zaq.Engine.IncomingMessageRouting
    alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}
    owner = self()
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    {spec, endpoint} =
      OpenAIStub.server(
        fn _conn, body ->
          request = Jason.decode!(body)

          if request["stream"] do
            send(owner, {:widget_model_waiting, self()})

            receive do
              :release_widget_answer ->
                {200, MultiAgentOpenAIStub.text_sse("Reconnected answer", request["model"])}
            after
              30_000 -> {500, %{error: "test model was not released"}}
            end
          else
            {200, OpenAIStub.chat_completion("Widget reload")}
          end
        end,
        self()
      )

    start_supervised!(spec)
    OpenAIStub.seed_llm_config(endpoint, model: "gpt-4.1-mini")

    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Widget reload",
        job: "Answer simply",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{"stream" => true}
      })

    config =
      %ChannelConfig{id: widget.id}
      |> ChannelConfig.changeset(
        Map.take(widget, [:name, :provider, :enabled, :token, :settings])
        |> Map.put(:kind, "retrieval")
      )
      |> Repo.insert!()

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(
        %{channel_config_id: config.id},
        %{routing_mode: :agent, configured_agent_id: agent.id}
      )

    {:ok, first_proof} = proof(widget)

    assert {:ok, chat} =
             Chat.open(
               to_string(widget.id),
               %{"identity_token" => first_proof},
               Ecto.UUID.generate()
             )

    assert {:ok, submitted} = Chat.submit(chat, "Please answer")
    assert_receive {:widget_model_waiting, model}, 30_000
    Chat.close(chat)
    {:ok, fresh_proof} = proof(widget)

    page =
      Task.async(fn ->
        assert {:ok, restored} =
                 Chat.open(
                   to_string(widget.id),
                   %{"identity_token" => fresh_proof},
                   Ecto.UUID.generate(),
                   submitted.conversation_id
                 )

        try do
          send(owner, {:widget_page_restored, restored.session.topic, restored.state.typing})

          receive do
            {:web_response, event, %{type: :message_complete} = response} ->
              recovered = Chat.receive_response(restored, event, response)
              Enum.map(recovered.state.messages, & &1.content)
          after
            30_000 -> flunk("original request did not reach the new widget page")
          end
        after
          Chat.close(restored)
        end
      end)

    assert_receive {:widget_page_restored, topic, true}, 30_000
    assert topic == chat.session.topic
    send(model, :release_widget_answer)
    assert Enum.count(Task.await(page, 30_000), &(&1 == "Reconnected answer")) == 1
  end

  test "installed adapter converges a user acknowledgement and its same-conversation broadcast",
       %{widget: widget} do
    alias WebWidget.Integration.Chat
    alias Zaq.Engine.IncomingMessageRouting
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    config =
      %ChannelConfig{id: widget.id}
      |> ChannelConfig.changeset(
        Map.take(widget, [:name, :provider, :enabled, :token, :settings])
        |> Map.put(:kind, "retrieval")
      )
      |> Repo.insert!()

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{routing_mode: :none})

    {:ok, token} = proof(widget)

    assert {:ok, first} =
             Chat.open(to_string(widget.id), %{"identity_token" => token}, Ecto.UUID.generate())

    assert {:ok, first} = Chat.submit(first, "Initial message")
    assert_receive {:web_response, "response.user_message", initial}
    first = Chat.receive_response(first, "response.user_message", initial)
    {:ok, token} = proof(widget)

    assert {:ok, second} =
             Chat.open(
               to_string(widget.id),
               %{"identity_token" => token},
               Ecto.UUID.generate(),
               first.conversation_id
             )

    try do
      assert {:ok, submitted} = Chat.submit(first, "Visible in both tabs")
      assert_receive {:web_response, "response.user_message", event}
      sender = Chat.receive_response(submitted, "response.user_message", event)
      observer = Chat.receive_response(second, "response.user_message", event)
      observer = Chat.receive_response(observer, "response.user_message", event)
      saved = event.payload.user_message

      for chat <- [sender, observer] do
        assert Enum.count(chat.state.messages, &(&1.content == "Visible in both tabs")) == 1
        assert Enum.any?(chat.state.messages, &(&1.id == saved.message_id))
        assert chat.pending_submission == nil
        refute chat.state.typing
      end
    after
      Chat.close(first)
      Chat.close(second)
    end
  end

  for name <- [
        WebWidget.Configuration,
        WebWidget.RuntimeRegistry,
        BindingStore,
        WebWidget.Supervisor
      ] do
    @crashed_child name
    test "#{name} restart recovers the same connector and isolates other bridges", %{
      widget: widget
    } do
      bridge_id = "unrelated_#{widget.id}"
      spec = %{id: bridge_id, start: {Agent, :start_link, [fn -> :unrelated end]}}

      assert {:ok, %{state_pid: unrelated}} =
               Zaq.Channels.Supervisor.start_runtime(bridge_id, spec)

      on_exit(fn -> Zaq.Channels.Supervisor.stop_bridge_runtime(%{}, bridge_id) end)

      assert {:ok, %{state_pid: connector}} =
               Zaq.Channels.Supervisor.lookup_runtime("web_widget_#{widget.id}")

      bridge_owner = Process.whereis(Zaq.Channels.BridgeSupervisor)
      old = await_widget(widget.id)
      pid = Process.whereis(@crashed_child)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      replacement = await_widget(widget.id, old.runtime_ref)
      refute replacement.runtime_ref == old.runtime_ref

      assert {:ok, %{state_pid: ^connector}} =
               Zaq.Channels.Supervisor.lookup_runtime("web_widget_#{widget.id}")

      assert Process.alive?(unrelated)
      assert Process.whereis(Zaq.Channels.BridgeSupervisor) == bridge_owner
    end
  end

  test "disabling during infrastructure downtime prevents resurrection", %{widget: widget} do
    assert {:ok, %{state_pid: connector}} =
             Zaq.Channels.Supervisor.lookup_runtime("web_widget_#{widget.id}")

    assert :ok =
             DynamicSupervisor.terminate_child(
               Zaq.Channels.BridgeSupervisor,
               Process.whereis(WebWidget.Supervisor)
             )

    try do
      assert :ok = WebBridge.sync_runtime(widget, %{widget | enabled: false})
      refute Process.alive?(connector)
    after
      replace_infrastructure(pubsub_server: Zaq.PubSub, session: [partitioned: false])
    end

    assert {:error, :not_running} =
             Zaq.Channels.Supervisor.lookup_runtime("web_widget_#{widget.id}")

    assert {:error, :runtime_not_registered} =
             WidgetRuntime.readiness_snapshot(to_string(widget.id), 300)
  end

  test "host socket wrapper rejects duplicate widget cookies before transport dispatch", %{
    widget: widget
  } do
    conn =
      build_conn()
      |> put_req_header("cookie", "_web_widget_session=first; _web_widget_session=second")
      |> get("/channels/widget/#{widget.id}/live/websocket")

    assert response(conn, 400) == "ambiguous_widget_cookie"
  end

  test "legacy omissions fail explicitly and installation snippet uses scoped widget route", %{
    widget: widget
  } do
    for key <- ["identity_issuer", "identity_audience", "same_site"] do
      legacy = %{
        widget
        | id: System.unique_integer([:positive]),
          settings: Map.delete(widget.settings, key)
      }

      assert {:error, :invalid_connector_configuration} = WebBridge.start_runtime(legacy)

      assert {:error, :not_running} =
               Zaq.Channels.Supervisor.lookup_runtime("web_widget_#{legacy.id}")
    end

    assert {:ok, snippet} =
             WebBridge.installation(
               %{op: :installation, config: widget, base_url: "https://zaq.example.test"},
               []
             )

    assert snippet =~ "/channels/widget/#{widget.id}"
    refute snippet =~ widget.token
  end

  test "real adapter enforces distinct connector claims and revokes the old runtime generation",
       %{widget: widget} do
    wait_for_authentication_store()

    second = %{
      widget
      | id: System.unique_integer([:positive]),
        settings:
          Map.merge(widget.settings, %{
            "identity_issuer" => "second_parent",
            "identity_audience" => "second_widget"
          })
    }

    assert :ok = WebBridge.start_runtime(second)
    on_exit(fn -> WebBridge.stop_runtime(second) end)

    assert {:ok, first_proof} = proof(widget)

    assert {:ok, first_session} =
             WidgetRuntime.authenticate(to_string(widget.id), first_proof, "first-page")

    assert {:ok, second_proof} = proof(second)

    assert {:ok, _} =
             WidgetRuntime.authenticate(to_string(second.id), second_proof, "second-page")

    assert {:error, :unauthorized} =
             WidgetRuntime.authenticate(to_string(second.id), first_proof, "wrong-page")

    wrong_claims = %{second | settings: widget.settings}
    assert {:ok, wrong_proof} = proof(wrong_claims)

    assert {:error, :unauthorized} =
             WidgetRuntime.authenticate(to_string(second.id), wrong_proof, "wrong-claims-page")

    changed = %{
      widget
      | settings: Map.put(widget.settings, "identity_issuer", "replacement_parent")
    }

    assert :ok = WebBridge.sync_runtime(widget, changed)

    assert {:error, :unauthorized} =
             WidgetRuntime.authenticate(to_string(widget.id), first_proof, "first-page")

    assert {:error, :unauthorized} = WidgetRuntime.subscribe(first_session)
    assert {:ok, replacement_proof} = proof(changed)

    assert {:ok, _} =
             WidgetRuntime.authenticate(
               to_string(widget.id),
               replacement_proof,
               "replacement-page"
             )

    rotated = %{changed | token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}
    assert :ok = WebBridge.sync_runtime(changed, rotated)
    assert {:ok, old_key_proof} = proof(changed)

    assert {:error, :unauthorized} =
             WidgetRuntime.authenticate(to_string(widget.id), old_key_proof, "old-key-page")

    assert {:ok, rotated_proof} = proof(rotated)

    assert {:ok, _} =
             WidgetRuntime.authenticate(to_string(widget.id), rotated_proof, "rotated-key-page")
  end

  test "real local HTTP WebSocket readiness verifies the installed development cookie policy",
       %{widget: widget} do
    restart_endpoint(
      http: [ip: {127, 0, 0, 1}, port: 0],
      https: false
    )

    warm_listener(widget.id, :http)
    assert {:ok, %{status: :ok} = health} = WebBridge.channel_ingress_status(widget)
    assert health.effective_settings.same_site == %{value: "Lax", source: :connector}

    desired = %{widget | settings: Map.put(widget.settings, "same_site", "Strict")}

    assert {:ok, %{status: :error, reason: :cookie_policy_mismatch}} =
             WebBridge.channel_ingress_status(desired)

    assert :ok = Supervisor.terminate_child(Zaq.Supervisor, ZaqWeb.Endpoint)

    # Automatic discovery cannot identify an endpoint once it is stopped.
    assert {:ok, %{status: :unknown, reason: :transport_unverifiable}} =
             WebBridge.channel_ingress_status(widget)
  end

  test "HTTP-only feed is ready while secure sessions remain rejected", %{widget: widget} do
    restart_endpoint(
      http: [ip: {127, 0, 0, 1}, port: 0],
      https: false,
      force_ssl: false
    )

    replace_infrastructure(pubsub_server: Zaq.PubSub)
    assert {:ok, %{proxy: nil}} = WebWidget.Configuration.fetch()
    changed = %{widget | settings: Map.put(widget.settings, "same_site", "None")}
    assert :ok = WebBridge.sync_runtime(widget, changed)
    {:ok, {_, port}} = ZaqWeb.Endpoint.server_info(:http)
    path = "/channels/widget/#{widget.id}"

    for suffix <- ["", "/session"] do
      response = Req.get!("http://localhost:#{port}#{path}#{suffix}", retry: false)
      assert response.status == 503
      assert response.body == "https_required"
      assert Req.Response.get_header(response, "set-cookie") == []
    end

    assert {:ok, %{status: :ok} = health} = WebBridge.channel_ingress_status(changed)
    assert health.effective_settings.same_site == %{value: "None", source: :connector}

    assert health.verification == %{
             scope: :local,
             session_handshake: :not_checked,
             external_https: :not_checked
           }

    assert :ok = Supervisor.terminate_child(Zaq.Supervisor, ZaqWeb.Endpoint)

    assert {:ok, %{status: :unknown, reason: :transport_unverifiable}} =
             WebBridge.channel_ingress_status(changed)
  end

  @tag :tmp_dir
  test "proxy-only HTTPS supports Secure cookies and WSS without a ZAQ TLS listener", %{
    widget: widget,
    tmp_dir: directory
  } do
    assert_proxy_only_tls(widget, directory, :explicit)
  end

  test "public URL and forwarding headers alone do not enable host HTTPS normalization", %{
    widget: widget
  } do
    restart_endpoint(
      http: [ip: {127, 0, 0, 1}, port: 0],
      https: false,
      url: [scheme: "https", host: "localhost", port: 443],
      force_ssl: false
    )

    replace_infrastructure(pubsub_server: Zaq.PubSub)
    changed = %{widget | settings: Map.put(widget.settings, "same_site", "None")}
    assert :ok = WebBridge.sync_runtime(widget, changed)

    response =
      build_conn()
      |> put_req_header("x-forwarded-proto", "https")
      |> get("/channels/widget/#{widget.id}/session")

    assert response.status == 503
    assert response.resp_body == "https_required"
    assert response.resp_cookies == %{}
  end

  test "configured host normalization rejects ambiguous schemes without creating cookies", %{
    widget: widget
  } do
    restart_endpoint(
      http: [ip: {127, 0, 0, 1}, port: 0],
      https: false,
      force_ssl: [rewrite_on: [:x_forwarded_proto]]
    )

    replace_infrastructure(pubsub_server: Zaq.PubSub)
    changed = %{widget | settings: Map.put(widget.settings, "same_site", "None")}
    assert :ok = WebBridge.sync_runtime(widget, changed)

    for scheme <- ["http", "", "https,http", "https, https", "invalid"] do
      response =
        build_conn()
        |> put_req_header("x-forwarded-proto", scheme)
        |> get("/channels/widget/#{widget.id}/session")

      assert response.status == 503
      assert response.resp_body == "https_required"
      assert response.resp_cookies == %{}
    end
  end

  @tag :tmp_dir
  test "ngrok-style HTTPS ingress without a forwarded port supports isolated cookies and WSS", %{
    widget: widget,
    tmp_dir: directory
  } do
    assert_proxy_only_tls(widget, directory, :omit)
  end

  @tag :tmp_dir
  test "host HTTPS normalization supports ngrok ingress without widget proxy configuration", %{
    widget: widget,
    tmp_dir: directory
  } do
    assert_proxy_only_tls(widget, directory, :omit, :host)
  end

  defp assert_proxy_only_tls(widget, directory, forwarded_port, policy \\ :widget) do
    restart_endpoint(
      http: [ip: {127, 0, 0, 1}, port: 0],
      https: false
    )

    {:ok, {_, backend_port}} = ZaqWeb.Endpoint.server_info(:http)
    tls = Zaq.WidgetTLSFixtures.certificates(directory)

    proxy =
      start_supervised!(
        {Zaq.WidgetProxyFixtures,
         backend_port: backend_port,
         keyfile: tls.keyfile,
         certfile: tls.certfile,
         forwarded_port: forwarded_port}
      )

    port = Zaq.WidgetProxyFixtures.port(proxy)

    origin =
      if forwarded_port == :omit and policy == :widget,
        do: "https://localhost",
        else: "https://localhost:#{port}"

    proxy_url = "https://localhost:#{port}"

    changes = [
      url: [
        host: "localhost",
        port: if(forwarded_port == :omit and policy == :widget, do: 443, else: port),
        scheme: "https"
      ]
    ]

    changes =
      if policy == :host,
        do: Keyword.put(changes, :force_ssl, rewrite_on: [:x_forwarded_proto]),
        else: changes

    current = Keyword.merge(Application.fetch_env!(:zaq, ZaqWeb.Endpoint), changes)
    Application.put_env(:zaq, ZaqWeb.Endpoint, current)
    ZaqWeb.Endpoint.config_change([{ZaqWeb.Endpoint, current}], [])

    if policy == :host do
      replace_infrastructure(pubsub_server: Zaq.PubSub)
      assert {:ok, %{proxy: nil}} = WebWidget.Configuration.fetch()
    else
      replace_infrastructure(
        pubsub_server: Zaq.PubSub,
        proxy: [trusted_proxies: [{127, 0, 0, 1}], public_origin: origin]
      )
    end

    changed = %{widget | settings: Map.put(widget.settings, "same_site", "None")}
    assert :ok = WebBridge.sync_runtime(widget, changed)

    options = [
      connect_options: [hostname: "localhost", transport_opts: [cacertfile: tls.cacertfile]],
      headers: [{"origin", origin}],
      retry: false
    ]

    path = "/channels/widget/#{widget.id}"
    assert %{status: 200, body: page} = Req.get!(proxy_url <> path, options)
    assert page =~ path <> "/live"
    session = Req.get!(proxy_url <> path <> "/session", options)
    assert session.status == 200
    [cookie_header] = Req.Response.get_header(session, "set-cookie")

    for attribute <- ["secure", "httponly", "samesite=none", "partitioned", "path=#{path}"] do
      assert String.downcase(cookie_header) =~ String.downcase(attribute)
    end

    refute cookie_header =~ "_zaq_key"
    cookie = hd(String.split(cookie_header, ";"))

    verified =
      Req.get!(
        proxy_url <> path <> "/session?verify=1",
        Keyword.put(options, :headers, [{"cookie", cookie}, {"origin", origin}])
      )

    assert verified.status == 200
    assert Req.Response.get_header(verified, "set-cookie") == []

    if policy == :host do
      # The ingress fixture replaces client forwarding headers, rather than trusting them.
      sanitized =
        Req.get!(
          proxy_url <> path,
          Keyword.put(options, :headers, [
            {"origin", origin},
            {"x-forwarded-proto", "http"},
            {"x-forwarded-host", "evil.example"},
            {"x-forwarded-port", "1"}
          ])
        )

      assert sanitized.status == 200
      assert Req.Response.get_header(sanitized, "set-cookie") == []
    end

    assert_proxy_websocket(
      port,
      tls.cacertfile,
      path,
      cookie,
      verified.body["csrf_token"],
      origin
    )

    assert_proxy_websocket(port, tls.cacertfile, path, cookie, "forged-csrf", origin, 403)

    assert_proxy_websocket(
      port,
      tls.cacertfile,
      path,
      cookie,
      verified.body["csrf_token"],
      "https://evil.example",
      403
    )

    assert {:error, _} = ZaqWeb.Endpoint.server_info(:https)

    assert %{status: 503, body: "https_required"} =
             Req.get!("http://localhost:#{backend_port}#{path}", retry: false)

    assert {:ok, %{status: :ok, verification: verification}} =
             WebBridge.channel_ingress_status(changed)

    assert verification == %{
             scope: :local,
             session_handshake: :not_checked,
             external_https: :not_checked
           }

    stop_supervised!(Zaq.WidgetProxyFixtures)

    assert {:ok, %{status: :ok, verification: ^verification}} =
             WebBridge.channel_ingress_status(changed)
  end

  @tag :tmp_dir
  test "real TLS widget WebSocket reports None/Secure ready while BO cookies stay Lax", %{
    widget: widget,
    tmp_dir: directory
  } do
    tls = start_tls_listener(directory)

    changed = %{widget | settings: Map.put(widget.settings, "same_site", "None")}
    assert :ok = WebBridge.sync_runtime(widget, changed)
    warm_listener(changed.id, :https, tls.cacertfile)
    assert {:ok, %{status: :ok} = health} = WebBridge.channel_ingress_status(changed)
    assert health.effective_settings.same_site == %{value: "None", source: :connector}

    session = get(build_conn(), "https://localhost/channels/widget/#{widget.id}/session")
    assert %{"csrf_token" => _} = json_response(session, 200)
    assert session.resp_cookies["_web_widget_session"].same_site == "None"
    assert session.resp_cookies["_web_widget_session"].secure
    assert session.resp_cookies["_web_widget_session"].extra == "Partitioned"
    refute Map.has_key?(session.resp_cookies, "_zaq_key")

    Zaq.AccountsFixtures.admin_fixture(%{must_change_password: false})
    bo = get(build_conn(), "https://localhost/bo/login")
    assert html_response(bo, 200) =~ "html"
    assert bo.resp_cookies["_zaq_key"].same_site == "Lax"
    refute Map.has_key?(bo.resp_cookies, "_web_widget_session")
  end

  @tag :tmp_dir
  test "BO saves, enables and rebuilds the real dependency with Ready on both status surfaces", %{
    conn: conn,
    tmp_dir: directory
  } do
    tls = start_tls_listener(directory)
    Mox.stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> node() end)
    user = Zaq.AccountsFixtures.admin_fixture(%{must_change_password: false})
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, {_ip, port}} = ZaqWeb.Endpoint.server_info(:https)
    assert :ok = Zaq.System.set_global_base_url("https://localhost:#{port}")
    {:ok, view, _} = live(conn, "/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    refute has_element?(view, "#widget-adapter-error")
    assert has_element?(view, "#widget-identity-issuer[value='zaq_issuer']")
    assert has_element?(view, "#widget-same-site input[value='None']")

    view
    |> form("#widget-config-form",
      widget: %{name: "Installed dependency", allowed_domains: "https://parent.example.test"}
    )
    |> render_submit()

    saved = Zaq.Repo.get_by!(Zaq.Engine.ChannelConfig, name: "Installed dependency")
    on_exit(fn -> WebBridge.stop_runtime(%{id: saved.id, provider: "web_widget"}) end)
    view |> element("#generate-widget-key") |> render_click()
    assert has_element?(view, "#new-widget-key")
    view |> element("#close-widget-modal") |> render_click()
    view |> element("#toggle-widget-#{saved.id}") |> render_click()
    warm_listener(saved.id, :https, tls.cacertfile)
    send(view.pid, :refresh_widget_statuses)
    render_async(view, 8_000)
    assert has_element?(view, "#widget-health-#{saved.id}", "Ready")
    assert has_element?(view, "#widget-connector-#{saved.id}", "Enabled")

    {:ok, list, _} = live(conn, "/bo/channels/retrieval")
    render_async(list, 8_000)
    assert has_element?(list, "#ingress-status-dot-web_widget .status-success")

    view |> element("#edit-widget-#{saved.id}") |> render_click()

    view
    |> form("#widget-config-form", widget: %{identity_issuer: "edited_parent"})
    |> render_submit()

    render_async(view, 8_000)
    assert has_element?(view, "#widget-identity-issuer[value='edited_parent']")
    assert has_element?(view, "#widget-health-#{saved.id}", "Ready")
    assert has_element?(view, "#widget-config-form", "Effective: edited_parent (connector)")
    assert {:ok, widget} = WidgetRuntime.fetch_widget(to_string(saved.id))
    assert widget.same_site == "None"

    assert Zaq.Repo.get!(Zaq.Engine.ChannelConfig, saved.id).settings["identity_issuer"] ==
             "edited_parent"
  end

  property "distinct connector paths cannot overwrite one another's cookie scope", %{
    widget: widget
  } do
    check all(offset <- integer(1..1000)) do
      second = %{widget | id: widget.id + offset}
      assert :ok = WebBridge.start_runtime(second)

      try do
        first_session = get(build_conn(), "/channels/widget/#{widget.id}/session")
        second_session = get(build_conn(), "/channels/widget/#{second.id}/session")

        assert first_session.resp_cookies["_web_widget_session"].path !=
                 second_session.resp_cookies["_web_widget_session"].path
      after
        WebBridge.stop_runtime(second)
      end
    end
  end

  test "signed parent profile reaches People through the real adapter", %{widget: widget} do
    previous_base_url = ZaqSystem.get_global_base_url()
    :ok = ZaqSystem.set_global_base_url("https://zaq.example.test")
    on_exit(fn -> ZaqSystem.set_global_base_url(previous_base_url) end)

    %ChannelConfig{id: widget.id}
    |> ChannelConfig.changeset(
      Map.take(widget, [:name, :provider, :enabled, :token, :settings])
      |> Map.put(:kind, "retrieval")
    )
    |> Repo.insert!()

    CommunicationFixtures.connector_fixture("email")

    if is_nil(Process.whereis(Zaq.Channels.Supervisor)) do
      start_supervised!(%{
        id: Zaq.Channels.Supervisor,
        start:
          {Supervisor, :start_link, [[], [strategy: :one_for_one, name: Zaq.Channels.Supervisor]]}
      })
    end

    {:ok, assertion} =
      SignedIdentity.sign(
        widget.token,
        widget.id,
        %{
          user_id: "profile-user",
          profile: %{full_name: "Ada Lovelace", email: "ada@example.com", phone: "+14155550123"}
        },
        issuer: widget.settings["identity_issuer"],
        audience: widget.settings["identity_audience"]
      )

    assert {:ok, session} =
             WidgetRuntime.authenticate(to_string(widget.id), assertion, "profile-page")

    if is_nil(Process.whereis(Zaq.Engine.Supervisor)) do
      start_supervised!(%{
        id: Zaq.Engine.Supervisor,
        start:
          {Supervisor, :start_link, [[], [strategy: :one_for_one, name: Zaq.Engine.Supervisor]]}
      })
    end

    assert {:ok, response, _bound_session} =
             WidgetRuntime.initialize(
               %{
                 type: "widget.init",
                 request_id: "profile-init",
                 conversation_id: nil,
                 params: %{}
               },
               session
             )

    assert response.type == :widget_initialized
    assert {:ok, person} = People.match_by_channel("web_widget", "profile-user", widget.id)
    assert person.full_name == "Ada Lovelace"
    assert person.email == "ada@example.com"
    assert person.phone == "+14155550123"
    assert {:ok, linked} = People.match_by_channel("web_widget", "profile-user", widget.id)
    assert linked.id == person.id
  end

  defp proof(widget) do
    SignedIdentity.sign(widget.token, widget.id, %{user_id: "test-parent-user"},
      issuer: widget.settings["identity_issuer"],
      audience: widget.settings["identity_audience"]
    )
  end

  # Infrastructure may wait up to five seconds for killed Registry partitions;
  # allow that documented startup budget plus the connector's bounded retry.
  defp await_widget(id, old_ref \\ nil, attempts \\ 400)

  defp await_widget(id, _old_ref, 0) do
    owners =
      Map.new(
        [
          WebWidget.Supervisor,
          WebWidget.Configuration,
          WebWidget.RuntimeRegistry,
          BindingStore,
          Zaq.Channels.BridgeSupervisor
        ],
        &{&1, Process.whereis(&1)}
      )

    flunk(
      "Widget did not recover: #{inspect(owners)}; snapshot=#{inspect(WidgetRuntime.readiness_snapshot(to_string(id), 300) |> elem(0))}"
    )
  end

  defp await_widget(id, old_ref, attempts) do
    case WidgetRuntime.readiness_snapshot(to_string(id), 300) do
      {:ok, %{runtime_ref: ref} = snapshot} when ref != old_ref ->
        snapshot

      _ ->
        receive do
        after
          25 -> await_widget(id, old_ref, attempts - 1)
        end
    end
  end

  defp wait_for_authentication_store(attempts \\ 30)

  defp wait_for_authentication_store(0),
    do: flunk("Widget authentication store did not become ready")

  defp wait_for_authentication_store(attempts) do
    now = System.system_time(:second)

    case BindingStore.reset_cutoff_value() do
      cutoff when is_integer(cutoff) and cutoff < now ->
        :ok

      _ ->
        receive do
        after
          100 -> wait_for_authentication_store(attempts - 1)
        end
    end
  end

  defp restart_endpoint(options) do
    previous = Application.fetch_env!(:zaq, ZaqWeb.Endpoint)
    assert :ok = Supervisor.terminate_child(Zaq.Supervisor, ZaqWeb.Endpoint)

    current =
      Keyword.merge(previous,
        server: true,
        watchers: [],
        code_reloader: false,
        url: [host: "localhost"],
        check_origin: true
      )

    Application.put_env(:zaq, ZaqWeb.Endpoint, Keyword.merge(current, options))
    assert {:ok, _} = Supervisor.restart_child(Zaq.Supervisor, ZaqWeb.Endpoint)

    on_exit(fn ->
      Supervisor.terminate_child(Zaq.Supervisor, ZaqWeb.Endpoint)
      Application.put_env(:zaq, ZaqWeb.Endpoint, previous)
      Supervisor.restart_child(Zaq.Supervisor, ZaqWeb.Endpoint)
    end)
  end

  defp start_tls_listener(directory) do
    tls = Zaq.WidgetTLSFixtures.certificates(directory)

    restart_endpoint(
      http: false,
      https: [ip: {127, 0, 0, 1}, port: 0, keyfile: tls.keyfile, certfile: tls.certfile]
    )

    previous = [pubsub_server: Zaq.PubSub]

    replace_infrastructure(
      Keyword.put(previous, :transport, tls_options: [cacertfile: tls.cacertfile])
    )

    on_exit(fn -> replace_infrastructure(previous) end)

    tls
  end

  defp replace_infrastructure(opts) do
    if pid = Process.whereis(WebWidget.Supervisor),
      do: DynamicSupervisor.terminate_child(Zaq.Channels.BridgeSupervisor, pid)

    assert {:ok, [spec]} =
             WebWidget.HostAdapter.infrastructure_child_specs(
               Keyword.put(opts, :scope, "/channels")
             )

    assert {:ok, _} = DynamicSupervisor.start_child(Zaq.Channels.BridgeSupervisor, spec)
  end

  defp assert_proxy_websocket(port, ca, path, cookie, csrf, origin, expected_status \\ 101) do
    {:ok, conn} =
      Mint.HTTP.connect(:https, {127, 0, 0, 1}, port,
        mode: :passive,
        protocols: [:http1],
        hostname: "localhost",
        transport_opts: [cacertfile: String.to_charlist(ca)]
      )

    key = Base.encode64(:crypto.strong_rand_bytes(16))
    query = URI.encode_query(%{"_csrf_token" => csrf, "vsn" => "2.0.0"})

    headers = [
      {"host", "localhost:#{port}"},
      {"connection", "Upgrade"},
      {"upgrade", "websocket"},
      {"sec-websocket-version", "13"},
      {"sec-websocket-key", key},
      {"cookie", cookie},
      {"origin", origin}
    ]

    {:ok, conn, ref} =
      Mint.HTTP.request(conn, "GET", path <> "/live/websocket?" <> query, headers, nil)

    try do
      {:ok, _, responses} = Mint.HTTP.recv(conn, 0, 2_000)
      assert {:status, ref, expected_status} in responses

      if expected_status == 101 do
        expected =
          Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

        assert Enum.any?(responses, fn
                 {:headers, ^ref, response_headers} ->
                   {"sec-websocket-accept", expected} in response_headers

                 _ ->
                   false
               end)
      end
    after
      Mint.HTTP.close(conn)
    end
  end

  defp warm_listener(id, scheme, ca \\ nil) do
    assert {:ok, {_ip, port}} = ZaqWeb.Endpoint.server_info(scheme)
    options = if ca, do: [connect_options: [transport_opts: [cacertfile: ca]]], else: []

    assert %{status: 200} =
             Req.get!("#{scheme}://localhost:#{port}/channels/widget/#{id}", options)
  end
end
