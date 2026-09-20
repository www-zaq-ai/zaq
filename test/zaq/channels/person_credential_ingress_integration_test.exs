defmodule Zaq.Channels.PersonCredentialIngressIntegrationTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Jido.Chat.Mattermost.WebSocket.Client
  alias Zaq.Accounts.People
  alias Zaq.Agent
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.{ChannelConfig, JidoChatBridge}
  alias Zaq.Engine.{Connect, Conversations}
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Repo
  alias Zaq.TestSupport.{CredentialMutationJob, MultiAgentOpenAIStub, OpenAIStub}

  @environment_keys [
    :channels,
    :chat_bridge_pipeline_module,
    :chat_bridge_node_router_module,
    :chat_bridge_accounts_module,
    :chat_bridge_permissions_module,
    :chat_bridge_supervisor_module,
    :chat_bridge_chat_module,
    :pipeline_hooks_module
  ]

  setup do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")

    previous_environment =
      Map.new(@environment_keys, fn key -> {key, Application.fetch_env(:zaq, key)} end)

    Application.put_env(:zaq, :channels, %{
      mattermost: %{
        bridge: JidoChatBridge,
        adapter: Jido.Chat.Mattermost.Adapter,
        ingress_mode: :webhook
      }
    })

    Enum.each(@environment_keys -- [:channels], &Application.delete_env(:zaq, &1))

    on_exit(fn ->
      Enum.each(previous_environment, fn
        {key, {:ok, value}} -> Application.put_env(:zaq, key, value)
        {key, :error} -> Application.delete_env(:zaq, key)
      end)
    end)

    :ok
  end

  test "optional policy selects each Mattermost Person's effective authentication" do
    fixture = ingress_fixture(:optional)
    alice = add_person(fixture, "Optional Alice", "mm-optional-alice", "alice-key")
    bob = add_person(fixture, "Optional Bob", "mm-optional-bob")

    send_posted_frame(fixture, alice, "hello from alice")
    assert_receive {:llm_authorization, ["Bearer alice-key"]}, 5_000
    assert_delivered_answer(alice.channel_id)
    assert_persisted_answer(alice.person.id, "Ingress authorized", fixture.agent.id)

    send_posted_frame(fixture, bob, "hello from bob")
    assert_receive {:llm_authorization, ["Bearer org-key"]}, 5_000
    assert_delivered_answer(bob.channel_id)
    assert_persisted_answer(bob.person.id, "Ingress authorized", fixture.agent.id)

    assert length(agent_server_pids(fixture.agent)) == 2
  end

  test "disabled policy ignores a stored Person grant at Mattermost ingress" do
    fixture = ingress_fixture(:disabled)
    person = add_person(fixture, "Disabled Alice", "mm-disabled-alice", "inactive-person-key")

    send_posted_frame(fixture, person, "use the configured policy")

    assert_receive {:llm_authorization, ["Bearer org-key"]}, 5_000
    assert_delivered_answer(person.channel_id)
    assert_persisted_answer(person.person.id, "Ingress authorized", fixture.agent.id)
    refute_received {:llm_authorization, ["Bearer inactive-person-key"]}
  end

  test "required policy accepts a Person grant and rejects a missing grant before LLM HTTP" do
    fixture = ingress_fixture(:required)
    alice = add_person(fixture, "Required Alice", "mm-required-alice", "required-alice-key")
    bob = add_person(fixture, "Required Bob", "mm-required-bob")

    send_posted_frame(fixture, alice, "authorized person")
    assert_receive {:llm_authorization, ["Bearer required-alice-key"]}, 5_000
    assert_delivered_answer(alice.channel_id)
    assert_persisted_answer(alice.person.id, "Ingress authorized", fixture.agent.id)

    send_posted_frame(fixture, bob, "missing personal credential")

    assert_receive {:mattermost_post, %{"channel_id" => channel_id}, post_id}, 5_000
    assert channel_id == bob.channel_id

    assert_receive {:mattermost_update,
                    %{
                      "id" => ^post_id,
                      "message" =>
                        "Sorry, something went wrong while executing the selected agent."
                    }},
                   5_000

    refute_received {:llm_authorization, _authorization}
  end

  test "required policy works without an organization grant only for a Person with a grant" do
    fixture = ingress_fixture(:required, global_grant?: false)
    alice = add_person(fixture, "Personal Only Alice", "mm-personal-only-alice", "alice-only-key")
    bob = add_person(fixture, "Personal Only Bob", "mm-personal-only-bob")

    send_posted_frame(fixture, alice, "person grant without global")
    assert_receive {:llm_authorization, ["Bearer alice-only-key"]}, 5_000
    assert_delivered_answer(alice.channel_id)
    assert_persisted_answer(alice.person.id, "Ingress authorized", fixture.agent.id)

    send_posted_frame(fixture, bob, "no grant")
    assert_receive {:mattermost_post, %{"channel_id" => channel_id}, post_id}, 5_000
    assert channel_id == bob.channel_id

    assert_receive {:mattermost_update,
                    %{
                      "id" => ^post_id,
                      "message" =>
                        "Sorry, something went wrong while executing the selected agent."
                    }},
                   5_000

    refute_received {:llm_authorization, _authorization}
  end

  test "a provider-rejected Person credential never falls back to the organization grant" do
    fixture = ingress_fixture(:optional, reject_authorization: ["Bearer rejected-person-key"])

    person =
      add_person(fixture, "Rejected Alice", "mm-rejected-alice", "rejected-person-key")

    send_posted_frame(fixture, person, "reject my personal credential")

    outgoing =
      assert_delivered_error(
        person.channel_id,
        nil
      )

    assert outgoing.body =~ "The AI provider rejected the request."

    authorizations = drain_messages(:llm_authorization)
    assert authorizations != []
    assert Enum.uniq(authorizations) == [["Bearer rejected-person-key"]]
  end

  test "Person grant replacement and revocation fence only that Mattermost Person runtime" do
    fixture = ingress_fixture(:optional)
    alice = add_person(fixture, "Lifecycle Alice", "mm-lifecycle-alice", "alice-original-key")
    bob = add_person(fixture, "Lifecycle Bob", "mm-lifecycle-bob")

    send_posted_frame(fixture, alice, "warm alice")
    assert_receive {:llm_authorization, ["Bearer alice-original-key"]}, 5_000
    assert_delivered_answer(alice.channel_id)
    assert_persisted_answer(alice.person.id, "Ingress authorized", fixture.agent.id)
    alice_pid = person_server_pid(fixture.agent, alice.person.id)

    send_posted_frame(fixture, bob, "warm bob")
    assert_receive {:llm_authorization, ["Bearer org-key"]}, 5_000
    assert_delivered_answer(bob.channel_id)
    assert_persisted_answer(bob.person.id, "Ingress authorized", fixture.agent.id)
    bob_pid = person_server_pid(fixture.agent, bob.person.id)

    {{:ok, _grant}, replacement_job} =
      capture_credential_notification(fixture.connect_credential.id, fn ->
        Connect.replace_credential_grant(
          fixture.connect_credential,
          {:person, alice.person.id},
          %{api_key: "alice-replaced-key"}
        )
      end)

    send_posted_frame(fixture, alice, "before replacement delivery")
    assert_receive {:llm_authorization, ["Bearer alice-original-key"]}, 5_000
    assert_delivered_answer(alice.channel_id)
    assert_persisted_answer(alice.person.id, "Ingress authorized", fixture.agent.id)
    assert person_server_pid(fixture.agent, alice.person.id) == alice_pid

    alice_ref = Process.monitor(alice_pid)
    deliver_credential_notification(replacement_job)
    assert_receive {:DOWN, ^alice_ref, :process, ^alice_pid, _reason}, 5_000
    assert Process.alive?(bob_pid)

    send_posted_frame(fixture, alice, "after replacement delivery")
    assert_receive {:llm_authorization, ["Bearer alice-replaced-key"]}, 5_000
    assert_delivered_answer(alice.channel_id)
    assert_persisted_answer(alice.person.id, "Ingress authorized", fixture.agent.id)
    replacement_pid = person_server_pid(fixture.agent, alice.person.id)
    replacement_ref = Process.monitor(replacement_pid)

    {{:ok, _grant}, revocation_job} =
      capture_credential_notification(fixture.connect_credential.id, fn ->
        Connect.revoke_credential_grant(
          fixture.connect_credential,
          {:person, alice.person.id}
        )
      end)

    deliver_credential_notification(revocation_job)
    assert_receive {:DOWN, ^replacement_ref, :process, ^replacement_pid, _reason}, 5_000
    assert Process.alive?(bob_pid)

    send_posted_frame(fixture, alice, "after revocation")

    assert_delivered_error(
      alice.channel_id,
      %{credential_id: fixture.connect_credential.id, reason: :credential_revoked}
    )

    refute_received {:llm_authorization, _authorization}
    assert Process.alive?(bob_pid)
  end

  test "policy and global grant changes apply lazily to Mattermost Person runtimes" do
    fixture = ingress_fixture(:optional)
    alice = add_person(fixture, "Policy Alice", "mm-policy-alice", "policy-alice-key")
    bob = add_person(fixture, "Policy Bob", "mm-policy-bob")

    send_posted_frame(fixture, alice, "optional personal")
    assert_receive {:llm_authorization, ["Bearer policy-alice-key"]}, 5_000
    assert_delivered_answer(alice.channel_id)
    assert_persisted_answer(alice.person.id, "Ingress authorized", fixture.agent.id)
    alice_pid = person_server_pid(fixture.agent, alice.person.id)

    send_posted_frame(fixture, bob, "optional global")
    assert_receive {:llm_authorization, ["Bearer org-key"]}, 5_000
    assert_delivered_answer(bob.channel_id)
    assert_persisted_answer(bob.person.id, "Ingress authorized", fixture.agent.id)
    bob_pid = person_server_pid(fixture.agent, bob.person.id)

    alice_ref = Process.monitor(alice_pid)
    bob_ref = Process.monitor(bob_pid)

    {{:ok, required_credential}, required_job} =
      capture_credential_notification(fixture.connect_credential.id, fn ->
        Connect.update_credential(fixture.connect_credential, %{
          personal_credential_policy: :required
        })
      end)

    deliver_credential_notification(required_job)
    assert_receive {:DOWN, ^alice_ref, :process, ^alice_pid, _reason}, 5_000
    assert_receive {:DOWN, ^bob_ref, :process, ^bob_pid, _reason}, 5_000

    send_posted_frame(fixture, bob, "required without personal")

    assert_delivered_error(
      bob.channel_id,
      %{credential_id: fixture.connect_credential.id, reason: :personal_credential_required}
    )

    refute_received {:llm_authorization, _authorization}

    {{:ok, disabled_credential}, disabled_job} =
      capture_credential_notification(fixture.connect_credential.id, fn ->
        Connect.update_credential(required_credential, %{
          personal_credential_policy: :disabled
        })
      end)

    deliver_credential_notification(disabled_job)

    send_posted_frame(fixture, alice, "disabled ignores personal")
    assert_receive {:llm_authorization, ["Bearer org-key"]}, 5_000
    assert_delivered_answer(alice.channel_id)
    assert_persisted_answer(alice.person.id, "Ingress authorized", fixture.agent.id)

    send_posted_frame(fixture, bob, "disabled uses global")
    assert_receive {:llm_authorization, ["Bearer org-key"]}, 5_000
    assert_delivered_answer(bob.channel_id)
    assert_persisted_answer(bob.person.id, "Ingress authorized", fixture.agent.id)

    old_global_pids = agent_server_pids(fixture.agent)
    assert length(old_global_pids) == 2
    global_refs = Enum.map(old_global_pids, &Process.monitor/1)

    {{:ok, _grant}, global_job} =
      capture_credential_notification(fixture.connect_credential.id, fn ->
        Connect.replace_credential_grant(disabled_credential, :org, %{api_key: "org-key-2"})
      end)

    send_posted_frame(fixture, bob, "before global notification")
    assert_receive {:llm_authorization, ["Bearer org-key"]}, 5_000
    assert_delivered_answer(bob.channel_id)
    assert_persisted_answer(bob.person.id, "Ingress authorized", fixture.agent.id)

    deliver_credential_notification(global_job)

    Enum.zip(global_refs, old_global_pids)
    |> Enum.each(fn {ref, pid} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end)

    send_posted_frame(fixture, bob, "after global notification")
    assert_receive {:llm_authorization, ["Bearer org-key-2"]}, 5_000
    assert_delivered_answer(bob.channel_id)
    assert_persisted_answer(bob.person.id, "Ingress authorized", fixture.agent.id)
  end

  test "Mattermost Person identity propagates through nested X to Y and back to X" do
    y_id_ref = :atomics.new(1, [])

    responder = fn body ->
      cond do
        body =~ "MARKER_INGRESS_AGENT_Y" ->
          MultiAgentOpenAIStub.text_sse("ANSWER_FROM_Y", "gpt-4.1-mini")

        MultiAgentOpenAIStub.tool_result?(body) ->
          MultiAgentOpenAIStub.text_sse("X_FINAL_OK", "gpt-4.1-mini")

        true ->
          MultiAgentOpenAIStub.tool_call_sse(
            "run_agent",
            %{agent_id: :atomics.get(y_id_ref, 1), input: "ask Y"},
            model: "gpt-4.1-mini"
          )
      end
    end

    fixture =
      ingress_fixture(:optional,
        llm_responder: responder,
        agent_attrs: %{
          job: "MARKER_INGRESS_AGENT_X. Consult Y, then answer.",
          enabled_tool_keys: ["workflow.run_agent"]
        }
      )

    {:ok, agent_y} =
      Agent.create_agent(%{
        name: "Ingress Nested Y #{System.unique_integer([:positive, :monotonic])}",
        description: "",
        job: "MARKER_INGRESS_AGENT_Y. Answer briefly.",
        model: "gpt-4.1-mini",
        credential_id: fixture.credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    :atomics.put(y_id_ref, 1, agent_y.id)
    on_exit(fn -> _ = ServerManager.stop_server(agent_y) end)

    person = add_person(fixture, "Nested Ingress Alice", "mm-nested-alice", "nested-alice-key")

    send_posted_frame(fixture, person, "consult Y")

    assert List.duplicate(["Bearer nested-alice-key"], 3) ==
             receive_authorizations(3, [])

    assert_delivered_message(person.channel_id, "X_FINAL_OK")
    assert_persisted_answer(person.person.id, "X_FINAL_OK", fixture.agent.id)
    assert_runtime_person(fixture.agent, person.person.id)
    assert_runtime_person(agent_y, person.person.id)
  end

  defp ingress_fixture(policy, opts \\ []) do
    test_pid = self()

    {child_spec, endpoint} =
      OpenAIStub.server(
        fn conn, body -> ingress_http_response(conn, body, test_pid, opts) end,
        test_pid
      )

    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Ingress Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "org-key"
      })

    connect_credential = Connect.get_credential!(credential.connect_credential_id)

    assert {:ok, connect_credential} =
             Connect.update_credential(connect_credential, %{
               personal_credential_policy: policy
             })

    unless Keyword.get(opts, :global_grant?, true) do
      assert {:ok, _grant} = Connect.remove_credential_grant(connect_credential, :org)
    end

    agent_attrs =
      Map.merge(
        %{
          name: "Ingress Agent #{System.unique_integer([:positive, :monotonic])}",
          description: "",
          job: "Reply with Ingress authorized.",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: [],
          conversation_enabled: true,
          active: true,
          advanced_options: %{"stream" => false}
        },
        Keyword.get(opts, :agent_attrs, %{})
      )

    {:ok, agent} = Agent.create_agent(agent_attrs)

    channel_config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Ingress Mattermost #{System.unique_integer([:positive, :monotonic])}",
        provider: "mattermost",
        kind: "retrieval",
        url: String.trim_trailing(endpoint, "/v1"),
        token: "mattermost-token",
        enabled: true,
        settings: %{}
      })
      |> Repo.insert!()

    assert {:ok, _rule} =
             IncomingMessageRouting.upsert_rule(%{channel_config_id: channel_config.id}, %{
               routing_mode: :agent,
               configured_agent_id: agent.id
             })

    bridge_id = "mattermost_#{channel_config.id}"

    on_exit(fn ->
      _ = ServerManager.stop_server(agent)
      _ = Zaq.Channels.Supervisor.stop_bridge_runtime(channel_config, bridge_id)
    end)

    %{
      agent: agent,
      credential: credential,
      channel_config: channel_config,
      connect_credential: connect_credential,
      bridge_id: bridge_id
    }
  end

  defp add_person(fixture, name, mattermost_user_id, api_key \\ nil) do
    {:ok, person} =
      People.create_person(%{
        full_name: name,
        email: "#{mattermost_user_id}@example.test",
        phone: "+1555#{System.unique_integer([:positive])}"
      })

    channel_id = "dm-#{mattermost_user_id}"

    assert {:ok, _channel} =
             People.add_channel(%{
               person_id: person.id,
               platform: "mattermost",
               channel_identifier: mattermost_user_id,
               dm_channel_id: channel_id,
               weight: 0
             })

    if api_key do
      assert {:ok, _grant} =
               Connect.replace_credential_grant(
                 fixture.connect_credential,
                 {:person, person.id},
                 %{api_key: api_key}
               )
    end

    %{person: person, mattermost_user_id: mattermost_user_id, channel_id: channel_id}
  end

  defp send_posted_frame(fixture, person_fixture, message) do
    post = %{
      "id" => "post-#{System.unique_integer([:positive, :monotonic])}",
      "user_id" => person_fixture.mattermost_user_id,
      "channel_id" => person_fixture.channel_id,
      "message" => message,
      "root_id" => ""
    }

    frame =
      {:text,
       Jason.encode!(%{
         "event" => "posted",
         "data" => %{"channel_type" => "D", "post" => Jason.encode!(post)}
       })}

    state = %{
      token: "mattermost-token",
      url: fixture.channel_config.url,
      bot_user_id: "zaq-bot-user",
      bot_name: "zaq",
      channel_ids: :all,
      bridge_id: fixture.bridge_id,
      sink_mfa: {JidoChatBridge, :from_listener, [fixture.channel_config]},
      sink_opts: [bridge_id: fixture.bridge_id]
    }

    assert {:ok, %{auth_status: :ok}} = Client.handle_in(frame, state)
  end

  defp ingress_http_response(conn, body, test_pid, opts) do
    case conn.request_path do
      path when path in ["/v1/responses", "/v1/chat/completions"] ->
        authorization = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:llm_authorization, authorization})
        llm_http_response(path, body, authorization, opts)

      "/api/v4/users/me/typing" ->
        {200, %{}}

      "/api/v4/posts" ->
        payload = Jason.decode!(body)
        post_id = Ecto.UUID.generate()
        send(test_pid, {:mattermost_post, payload, post_id})
        {201, Map.merge(payload, %{"id" => post_id, "create_at" => 0})}

      "/api/v4/posts/" <> post_id ->
        payload = Jason.decode!(body)
        send(test_pid, {:mattermost_update, payload})
        {200, Map.merge(payload, %{"id" => post_id, "update_at" => 0})}
    end
  end

  defp llm_http_response(path, body, authorization, opts) do
    responder = Keyword.get(opts, :llm_responder)

    cond do
      authorization == Keyword.get(opts, :reject_authorization) ->
        {401,
         %{"error" => %{"message" => "invalid credential", "type" => "authentication_error"}}}

      is_function(responder, 1) ->
        {200, responder.(body)}

      true ->
        {200, streamed_reply(path, "Ingress authorized", "gpt-4.1-mini")}
    end
  end

  defp assert_delivered_answer(channel_id) do
    assert_delivered_message(channel_id, "Ingress authorized")
  end

  defp assert_delivered_message(channel_id, expected_message) do
    assert_receive {:mattermost_post, %{"channel_id" => ^channel_id}, post_id}, 5_000

    assert_receive {:mattermost_update, %{"id" => ^post_id, "message" => ^expected_message}},
                   5_000
  end

  defp assert_delivered_error(channel_id, expected_reason) do
    assert_receive {:mattermost_post, %{"channel_id" => ^channel_id}, post_id}, 5_000
    %Outgoing{} = outgoing = await_delivery_event()
    assert outgoing.metadata.error == true

    if expected_reason do
      assert outgoing.metadata.reason == inspect(expected_reason)
    end

    body = outgoing.body

    assert_receive {:mattermost_update, %{"id" => ^post_id, "message" => ^body}},
                   5_000

    outgoing
  end

  defp assert_persisted_answer(person_id, content, configured_agent_id) do
    %Outgoing{metadata: metadata} = await_delivery_event()
    conversation_id = metadata[:conversation_id] || metadata["conversation_id"]
    assistant_message_id = metadata[:assistant_message_id] || metadata["assistant_message_id"]

    assert metadata[:configured_agent_id] == configured_agent_id or
             metadata["configured_agent_id"] == configured_agent_id

    conversation = Conversations.get_conversation!(conversation_id)
    assert conversation.person_id == person_id

    assistant_message =
      conversation
      |> Conversations.list_messages()
      |> Enum.find(&(&1.id == assistant_message_id))

    assert assistant_message.content == content
  end

  defp await_delivery_event do
    receive do
      {:node_router_event, %Zaq.Event{opts: opts, request: %Outgoing{} = outgoing}} ->
        if opts[:action] == :deliver_outgoing do
          outgoing
        else
          await_delivery_event()
        end
    after
      5_000 -> flunk("timed out waiting for the persisted outgoing delivery event")
    end
  end

  defp agent_server_pids(agent) do
    registry = Jido.registry_name(Zaq.Agent.Jido)

    registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&String.starts_with?(&1, agent.name <> ":"))
    |> Enum.reject(&String.contains?(&1, "/"))
    |> Enum.flat_map(&Registry.lookup(registry, &1))
    |> Enum.map(&elem(&1, 0))
  end

  defp person_server_pid(agent, person_id) do
    registry = Jido.registry_name(Zaq.Agent.Jido)

    server_ids =
      registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.filter(fn server_id ->
        String.starts_with?(server_id, agent.name <> ":") and
          String.contains?(server_id, ":person:#{person_id}")
      end)
      |> Enum.reject(&String.contains?(&1, "/"))

    assert [server_id] = server_ids
    assert [{pid, _value}] = Registry.lookup(registry, server_id)
    pid
  end

  defp capture_credential_notification(credential_id, mutation) do
    CredentialMutationJob.capture!(credential_id, mutation)
  end

  defp deliver_credential_notification(job) do
    assert :ok = CredentialMutationJob.deliver!(job, "credential-ingress-test")
  end

  defp drain_messages(tag, acc \\ []) do
    receive do
      {^tag, value} -> drain_messages(tag, [value | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp receive_authorizations(0, acc), do: Enum.reverse(acc)

  defp receive_authorizations(count, acc) do
    assert_receive {:llm_authorization, authorization}, 5_000
    receive_authorizations(count - 1, [authorization | acc])
  end

  defp assert_runtime_person(agent, person_id) do
    assert [pid] = agent_server_pids(agent)
    assert {:ok, status} = Jido.AgentServer.status(pid)
    assert ActorNormalizer.person_id(status.raw_state.execution_actor) == person_id
  end

  defp streamed_reply("/v1/chat/completions", text, model) do
    chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-ingress",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]
      })

    done_chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-ingress",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 1, "total_tokens" => 6}
      })

    "data: #{chunk}\n\ndata: #{done_chunk}\n\ndata: [DONE]\n\n"
  end

  defp streamed_reply(_path, text, model) do
    delta_event = Jason.encode!(%{"delta" => text})

    completed_event =
      Jason.encode!(%{
        "response" => %{
          "id" => "resp_ingress",
          "model" => model,
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
        }
      })

    "event: response.output_text.delta\ndata: #{delta_event}\n\n" <>
      "event: response.completed\ndata: #{completed_event}\n\n"
  end
end
