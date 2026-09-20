defmodule Zaq.Agent.ExecutorIntegrationTest do
  use Zaq.DataCase, async: false

  import Ecto.Query
  import Zaq.SystemConfigFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.People
  alias Zaq.Agent
  alias Zaq.Agent.Answering
  alias Zaq.Agent.Executor
  alias Zaq.Agent.ServerManager
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Telemetry.Buffer
  alias Zaq.Engine.Telemetry.Point
  alias Zaq.{Event, NodeRouter}
  alias Zaq.Repo
  alias Zaq.System.AIProviderCredential

  alias Zaq.TestSupport.{
    ConnectOAuthAttemptConfig,
    ConnectOAuthAttemptHTTP,
    CredentialMutationJob,
    OpenAIStub
  }

  setup {Req.Test, :verify_on_exit!}

  defmodule StubAgent do
    def get_active_agent(_agent_id), do: {:ok, %{id: 77, name: "Stub Agent"}}
  end

  defmodule StubServerManager do
    def ensure_server(_configured_agent, _server_id, _context, actor: _actor),
      do: {:ok, :stub_server}
  end

  defmodule StubFactoryResult do
    def ask_with_config(_server, _content, _configured_agent, _opts \\ []),
      do: {:ok, %{request: :request, events: [completed_event(%{result: "from-result"})]}}

    def answering_configured_agent, do: %{id: :answering, name: "answering"}

    defp completed_event(data), do: %{kind: :request_completed, at_ms: 1, data: data}
  end

  defmodule StubFactoryAnswer do
    def ask_with_config(_server, _content, _configured_agent, _opts \\ []),
      do:
        {:ok,
         %{request: :request, events: [completed_event(%{result: %{answer: "from-answer"}})]}}

    def answering_configured_agent, do: %{id: :answering, name: "answering"}

    defp completed_event(data), do: %{kind: :request_completed, at_ms: 1, data: data}
  end

  defmodule StubFactoryOther do
    def ask_with_config(_server, _content, _configured_agent, _opts \\ []),
      do: {:ok, %{request: :request, events: [completed_event(%{result: %{unexpected: 123}})]}}

    def answering_configured_agent, do: %{id: :answering, name: "answering"}

    defp completed_event(data), do: %{kind: :request_completed, at_ms: 1, data: data}
  end

  defmodule StubFactoryStreamError do
    def ask_with_config(_server, _content, _configured_agent, _opts \\ []) do
      {:ok,
       %{
         request: :request,
         events: [
           %{
             kind: :request_failed,
             at_ms: 1,
             data: %{
               error:
                 ReqLLM.Error.API.Stream.exception(reason: "stream closed mid-flight", cause: nil)
             }
           }
         ]
       }}
    end

    def answering_configured_agent, do: %{id: :answering, name: "answering"}
  end

  defmodule StubFactoryAttachment do
    def ask_with_config(_server, content, _configured_agent, _opts \\ []) do
      send(self(), {:executor_question, content})

      {:ok,
       %{
         request: :request,
         events: [%{kind: :request_completed, at_ms: 1, data: %{result: "done"}}]
       }}
    end

    def answering_configured_agent, do: %{id: :answering, name: "answering"}
  end

  # Streams visible answer content, then the stream fails. The user already saw
  # tokens, so the error bubble must be suppressed.
  defmodule StubFactoryStreamErrorAfterContent do
    def ask_with_config(_server, _content, _configured_agent, _opts \\ []) do
      {:ok,
       %{
         request: :request,
         events: [
           %{
             kind: :llm_delta,
             at_ms: 1,
             data: %{chunk_type: :content, delta: "Partial answer already shown"}
           },
           %{
             kind: :request_failed,
             at_ms: 2,
             data: %{
               error:
                 ReqLLM.Error.API.Stream.exception(reason: "stream closed mid-flight", cause: nil)
             }
           }
         ]
       }}
    end

    def answering_configured_agent, do: %{id: :answering, name: "answering"}
  end

  test "runs configured agent end-to-end with only AI edge mocked" do
    handler = fn conn, body ->
      payload = Jason.decode!(body)
      assert payload["model"] == "gpt-4.1-mini"

      {200, streamed_reply(conn.request_path, "Yo", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "OpenAI Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Integration Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a helper. Reply with Yo.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming, agent_id: to_string(configured_agent.id), event: execution_event())

    assert is_binary(outgoing.body)
    assert outgoing.metadata.error == false
    assert outgoing.metadata.configured_agent_id == configured_agent.id
    assert outgoing.metadata.configured_agent_name == configured_agent.name

    assert_receive {:openai_request, "POST", "/v1/responses", "", _body}, 1_000
  end

  test "sends the policy-selected Person or global authentication to the LLM" do
    {configured_agent, credential, endpoint} = credential_agent_fixture(self())
    connect_credential = Connect.get_credential!(credential.connect_credential_id)
    {:ok, alice} = People.create_person(%{full_name: "Credential Alice"})
    {:ok, bob} = People.create_person(%{full_name: "Credential Bob"})

    assert {:ok, _grant} =
             Connect.replace_credential_grant(
               connect_credential,
               {:person, alice.id},
               %{api_key: "alice-key"}
             )

    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    assert_successful_execution(configured_agent, %{person: %{id: alice.id}}, alice)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer org-key"]}

    assert_successful_execution(configured_agent, %{kind: :system, subject: "policy-matrix"})
    assert_receive {:llm_authorization, ^endpoint, ["Bearer org-key"]}

    assert {:ok, connect_credential} =
             Connect.update_credential(connect_credential, %{
               personal_credential_policy: :optional
             })

    stop_agent_servers(configured_agent)

    assert_successful_execution(configured_agent, %{person: %{id: alice.id}}, alice)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer alice-key"]}

    # A second request proves warm reuse keeps the authentication selected at startup.
    assert_successful_execution(configured_agent, %{person: %{id: alice.id}}, alice)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer alice-key"]}

    assert_successful_execution(configured_agent, %{person: %{id: bob.id}}, bob)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer org-key"]}

    assert {:ok, connect_credential} =
             Connect.update_credential(connect_credential, %{
               personal_credential_policy: :required
             })

    stop_agent_servers(configured_agent)

    assert_successful_execution(configured_agent, %{person: %{id: alice.id}}, alice)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer alice-key"]}

    assert_failed_execution(
      configured_agent,
      %{person: %{id: bob.id}},
      bob,
      %{credential_id: connect_credential.id, reason: :personal_credential_required}
    )

    refute_received {:llm_authorization, ^endpoint, _headers}

    assert_successful_execution(configured_agent, %{kind: :system, subject: "policy-matrix"})
    assert_receive {:llm_authorization, ^endpoint, ["Bearer org-key"]}

    assert {:ok, _} = Connect.remove_credential_grant(connect_credential, :org)
    stop_agent_servers(configured_agent)

    assert_successful_execution(configured_agent, %{person: %{id: alice.id}}, alice)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer alice-key"]}

    assert_failed_execution(
      configured_agent,
      %{kind: :system, subject: "policy-matrix"},
      nil,
      %{credential_id: connect_credential.id, reason: :global_credential_missing}
    )

    refute_received {:llm_authorization, ^endpoint, _headers}
  end

  test "a rejected personal credential is never retried with the global credential" do
    test_pid = self()

    handler = fn conn, _body ->
      authorization = Plug.Conn.get_req_header(conn, "authorization")
      send(test_pid, {:rejected_authorization, authorization})

      {401,
       %{
         "error" => %{
           "message" => "invalid credential",
           "type" => "authentication_error"
         }
       }}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "org-key"
      })

    connect_credential = Connect.get_credential!(credential.connect_credential_id)

    assert {:ok, connect_credential} =
             Connect.update_credential(connect_credential, %{
               personal_credential_policy: :optional
             })

    {:ok, alice} = People.create_person(%{full_name: "Rejected Credential Alice"})

    assert {:ok, _grant} =
             Connect.replace_credential_grant(
               connect_credential,
               {:person, alice.id},
               %{api_key: "rejected-alice-key"}
             )

    {:ok, configured_agent} = create_http_agent(credential)
    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    assert_failed_execution(configured_agent, %{person: %{id: alice.id}}, alice, nil)

    authorizations = drain_messages(:rejected_authorization)
    assert authorizations != []
    assert Enum.uniq(authorizations) == [["Bearer rejected-alice-key"]]
  end

  test "persisted credential mutations fence targeted runtimes before the next LLM request" do
    {configured_agent, credential, endpoint} = credential_agent_fixture(self())
    connect_credential = Connect.get_credential!(credential.connect_credential_id)
    {:ok, alice} = People.create_person(%{full_name: "Lifecycle Alice"})
    {:ok, bob} = People.create_person(%{full_name: "Lifecycle Bob"})

    assert {:ok, connect_credential} =
             Connect.update_credential(connect_credential, %{
               personal_credential_policy: :optional
             })

    assert {:ok, _grant} =
             Connect.replace_credential_grant(
               connect_credential,
               {:person, alice.id},
               %{api_key: "alice-original-key"}
             )

    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    assert_successful_execution(configured_agent, %{person: %{id: alice.id}}, alice)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer alice-original-key"]}
    [alice_pid] = agent_server_pids(configured_agent)

    assert_successful_execution(configured_agent, %{person: %{id: bob.id}}, bob)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer org-key"]}
    [bob_pid] = agent_server_pids(configured_agent) -- [alice_pid]

    alice_ref = Process.monitor(alice_pid)

    {{:ok, _grant}, replacement_job} =
      capture_credential_notification(connect_credential.id, fn ->
        Connect.replace_credential_grant(
          connect_credential,
          {:person, alice.id},
          %{api_key: "alice-replaced-key"}
        )
      end)

    assert_successful_execution(configured_agent, %{person: %{id: alice.id}}, alice)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer alice-original-key"]}
    assert [alice_pid] == agent_server_pids(configured_agent) -- [bob_pid]

    deliver_credential_notification(replacement_job)
    assert_receive {:DOWN, ^alice_ref, :process, ^alice_pid, _reason}, 5_000
    assert Process.alive?(bob_pid)
    refute_received {:llm_authorization, ^endpoint, _headers}

    assert_successful_execution(configured_agent, %{person: %{id: alice.id}}, alice)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer alice-replaced-key"]}

    [replacement_alice_pid] = agent_server_pids(configured_agent) -- [bob_pid]
    replacement_ref = Process.monitor(replacement_alice_pid)

    {{:ok, _}, revocation_job} =
      capture_credential_notification(connect_credential.id, fn ->
        Connect.revoke_credential_grant(connect_credential, {:person, alice.id})
      end)

    deliver_credential_notification(revocation_job)
    assert_receive {:DOWN, ^replacement_ref, :process, ^replacement_alice_pid, _reason}, 5_000
    assert Process.alive?(bob_pid)

    assert_failed_execution(
      configured_agent,
      %{person: %{id: alice.id}},
      alice,
      %{credential_id: connect_credential.id, reason: :credential_revoked}
    )

    refute_received {:llm_authorization, ^endpoint, _headers}

    bob_ref = Process.monitor(bob_pid)

    {{:ok, connect_credential}, required_policy_job} =
      capture_credential_notification(connect_credential.id, fn ->
        Connect.update_credential(connect_credential, %{
          personal_credential_policy: :required
        })
      end)

    deliver_credential_notification(required_policy_job)
    assert_receive {:DOWN, ^bob_ref, :process, ^bob_pid, _reason}, 5_000

    assert_failed_execution(
      configured_agent,
      %{person: %{id: bob.id}},
      bob,
      %{credential_id: connect_credential.id, reason: :personal_credential_required}
    )

    refute_received {:llm_authorization, ^endpoint, _headers}

    {{:ok, connect_credential}, disabled_policy_job} =
      capture_credential_notification(connect_credential.id, fn ->
        Connect.update_credential(connect_credential, %{
          personal_credential_policy: :disabled
        })
      end)

    deliver_credential_notification(disabled_policy_job)

    assert_successful_execution(configured_agent, %{person: %{id: alice.id}}, alice)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer org-key"]}

    assert_successful_execution(configured_agent, %{person: %{id: bob.id}}, bob)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer org-key"]}

    old_global_pids = agent_server_pids(configured_agent)
    global_refs = Enum.map(old_global_pids, &Process.monitor/1)

    {{:ok, _grant}, global_replacement_job} =
      capture_credential_notification(connect_credential.id, fn ->
        Connect.replace_credential_grant(connect_credential, :org, %{api_key: "org-key-2"})
      end)

    deliver_credential_notification(global_replacement_job)

    Enum.zip(global_refs, old_global_pids)
    |> Enum.each(fn {ref, pid} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end)

    assert_successful_execution(configured_agent, %{person: %{id: alice.id}}, alice)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer org-key-2"]}
  end

  test "the default answering Agent sends its Person-selected authentication to the LLM" do
    test_pid = self()

    handler = fn conn, _body ->
      send(test_pid, {:answering_authorization, Plug.Conn.get_req_header(conn, "authorization")})
      {200, streamed_reply(conn.request_path, "Answered", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)

    credential =
      seed_llm_config(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "answering-org-key",
        model: "gpt-4.1-mini"
      })

    connect_credential = Connect.get_credential!(credential.connect_credential_id)
    answering_agent = Answering.answering_configured_agent()
    on_exit(fn -> _ = ServerManager.stop_server(answering_agent) end)

    assert {:ok, connect_credential} =
             Connect.update_credential(connect_credential, %{
               personal_credential_policy: :optional
             })

    {:ok, person} = People.create_person(%{full_name: "Default Answering Person"})

    assert {:ok, _grant} =
             Connect.replace_credential_grant(
               connect_credential,
               {:person, person.id},
               %{api_key: "answering-person-key"}
             )

    incoming = %Incoming{
      content: "hello",
      channel_id: "answering-credential-test",
      provider: :web,
      person: person
    }

    outgoing = Executor.run(incoming, event: execution_event(%{person: %{id: person.id}}))

    assert outgoing.metadata.error == false
    assert_receive {:answering_authorization, ["Bearer answering-person-key"]}

    {:ok, fallback_person} = People.create_person(%{full_name: "Default Answering Fallback"})

    fallback_incoming = %Incoming{
      content: "hello",
      channel_id: "answering-credential-fallback-test",
      provider: :web,
      person: fallback_person
    }

    outgoing =
      Executor.run(fallback_incoming,
        event: execution_event(%{person: %{id: fallback_person.id}})
      )

    assert outgoing.metadata.error == false
    assert_receive {:answering_authorization, ["Bearer answering-org-key"]}

    old_answering_pids = agent_server_pids(answering_agent)
    answering_refs = Enum.map(old_answering_pids, &Process.monitor/1)

    {{:ok, _credential}, required_job} =
      capture_credential_notification(connect_credential.id, fn ->
        Connect.update_credential(connect_credential, %{
          personal_credential_policy: :required
        })
      end)

    deliver_credential_notification(required_job)

    Enum.zip(answering_refs, old_answering_pids)
    |> Enum.each(fn {ref, pid} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end)

    outgoing =
      Executor.run(fallback_incoming,
        event: execution_event(%{person: %{id: fallback_person.id}})
      )

    assert outgoing.metadata.error == true

    assert outgoing.metadata.reason ==
             inspect(%{
               credential_id: connect_credential.id,
               reason: :personal_credential_required
             })

    refute_received {:answering_authorization, _authorization}
  end

  test "OAuth refresh invalidates the runtime and refresh failure never selects the global token" do
    test_pid = self()

    handler = fn conn, _body ->
      send(test_pid, {:oauth_llm_authorization, Plug.Conn.get_req_header(conn, "authorization")})
      {200, streamed_reply(conn.request_path, "OAuth authorized", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)
    Code.ensure_loaded!(ConnectOAuthAttemptConfig)

    {:ok, credential_dto} =
      Connect.save_credential_configuration(nil, %{
        name: "OAuth runtime #{Ecto.UUID.generate()}",
        provider: "openai",
        auth_kind: "oauth2",
        secret_binding: :grant,
        personal_credential_policy: :required,
        client_id: "runtime-client",
        client_secret: "runtime-client-secret",
        scopes: ["responses"],
        metadata: %{
          "authorize_url" => "https://provider.example/authorize",
          "token_url" => "https://provider.example/token"
        }
      })

    connect_credential = Repo.get!(Credential, credential_dto.credential_id)

    {:ok, ai_credential} =
      %AIProviderCredential{}
      |> AIProviderCredential.changeset(%{
        name: "OAuth runtime AI #{Ecto.UUID.generate()}",
        provider: "openai",
        endpoint: endpoint,
        metadata: %{"auth_kind" => "oauth2"},
        connect_credential_id: connect_credential.id
      })
      |> Repo.insert()

    {:ok, person} = People.create_person(%{full_name: "OAuth Runtime Person"})

    assert {:ok, _} =
             Connect.replace_credential_grant(connect_credential, :org, %{
               access_token: "oauth-org-token",
               refresh_token: "oauth-org-refresh"
             })

    assert {:ok, personal_dto} =
             Connect.replace_credential_grant(
               connect_credential,
               {:person, person.id},
               %{
                 access_token: "oauth-person-old",
                 refresh_token: "oauth-person-refresh",
                 expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
               }
             )

    assert {:ok, _} =
             Connect.update_credential(connect_credential, %{
               personal_credential_policy: :optional
             })

    {:ok, configured_agent} = create_http_agent(ai_credential)
    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    assert_successful_execution(configured_agent, %{person: %{id: person.id}}, person)
    assert_receive {:oauth_llm_authorization, ["Bearer oauth-person-old"]}

    [old_server] = agent_server_pids(configured_agent)
    old_server_ref = Process.monitor(old_server)
    personal_grant = Repo.get!(Grant, personal_dto.grant_id)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "oauth-person-new",
        "refresh_token" => "oauth-person-refresh-2",
        "expires_in" => 3_600
      })
    end)

    {{:ok, refreshed}, refresh_job} =
      capture_credential_notification(connect_credential.id, fn ->
        Connect.refresh_grant(personal_grant, config: ConnectOAuthAttemptConfig)
      end)

    assert refreshed.id == personal_grant.id
    deliver_credential_notification(refresh_job)
    assert_receive {:DOWN, ^old_server_ref, :process, ^old_server, _reason}, 5_000

    assert_successful_execution(configured_agent, %{person: %{id: person.id}}, person)
    assert_receive {:oauth_llm_authorization, ["Bearer oauth-person-new"]}

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "refresh rejected"})
    end)

    assert {:error, {:oauth_refresh_failed, 400}} =
             Connect.refresh_grant(Repo.reload!(personal_grant),
               config: ConnectOAuthAttemptConfig
             )

    assert_successful_execution(configured_agent, %{person: %{id: person.id}}, person)
    assert_receive {:oauth_llm_authorization, ["Bearer oauth-person-new"]}
    refute_received {:oauth_llm_authorization, ["Bearer oauth-org-token"]}
  end

  test "cold expired Person OAuth refresh failure never reaches the LLM or falls back globally" do
    test_pid = self()

    handler = fn conn, body ->
      case conn.request_path do
        "/oauth/token" ->
          send(test_pid, {:oauth_refresh_attempt, body})
          {400, %{"error" => "invalid_grant"}}

        path when path in ["/v1/responses", "/v1/chat/completions"] ->
          send(
            test_pid,
            {:expired_oauth_llm_request, Plug.Conn.get_req_header(conn, "authorization")}
          )

          {200, streamed_reply(path, "unexpected", "gpt-4.1-mini")}
      end
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)
    token_url = String.trim_trailing(endpoint, "/v1") <> "/oauth/token"

    {:ok, credential_dto} =
      Connect.save_credential_configuration(nil, %{
        name: "Expired OAuth #{Ecto.UUID.generate()}",
        provider: "openai",
        auth_kind: "oauth2",
        secret_binding: :grant,
        personal_credential_policy: :required,
        client_id: "expired-client",
        client_secret: "expired-client-secret",
        scopes: ["responses"],
        metadata: %{
          "authorize_url" => "https://provider.example/authorize",
          "token_url" => token_url
        }
      })

    connect_credential = Repo.get!(Credential, credential_dto.credential_id)

    {:ok, ai_credential} =
      %AIProviderCredential{}
      |> AIProviderCredential.changeset(%{
        name: "Expired OAuth AI #{Ecto.UUID.generate()}",
        provider: "openai",
        endpoint: endpoint,
        metadata: %{"auth_kind" => "oauth2"},
        connect_credential_id: connect_credential.id
      })
      |> Repo.insert()

    {:ok, person} = People.create_person(%{full_name: "Expired OAuth Person"})

    assert {:ok, _grant} =
             Connect.replace_credential_grant(connect_credential, :org, %{
               access_token: "oauth-org-token",
               refresh_token: "oauth-org-refresh",
               expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
             })

    assert {:ok, connect_credential} =
             Connect.update_credential(connect_credential, %{
               personal_credential_policy: :optional
             })

    assert {:ok, personal_dto} =
             Connect.replace_credential_grant(
               connect_credential,
               {:person, person.id},
               %{
                 access_token: "expired-person-token",
                 refresh_token: "expired-person-refresh",
                 expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
               }
             )

    personal_grant = Repo.get!(Grant, personal_dto.grant_id)

    Repo.update!(
      Ecto.Changeset.change(personal_grant,
        expires_at:
          DateTime.utc_now()
          |> DateTime.add(-60, :second)
          |> DateTime.truncate(:second)
      )
    )

    {:ok, configured_agent} = create_http_agent(ai_credential)
    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    assert_failed_execution(
      configured_agent,
      %{person: %{id: person.id}},
      person,
      %{credential_id: connect_credential.id, reason: :credential_refresh_failed}
    )

    assert_receive {:oauth_refresh_attempt, refresh_body}, 5_000
    assert URI.decode_query(refresh_body)["grant_type"] == "refresh_token"
    refute_received {:expired_oauth_llm_request, _authorization}
  end

  test "natural authentication expiry timer stops the runtime before expired cold resolution" do
    {configured_agent, credential, endpoint} = credential_agent_fixture(self())
    connect_credential = Connect.get_credential!(credential.connect_credential_id)
    {:ok, person} = People.create_person(%{full_name: "Scheduled Expiry Person"})

    assert {:ok, connect_credential} =
             Connect.update_credential(connect_credential, %{
               personal_credential_policy: :optional
             })

    assert {:ok, _grant} =
             Connect.replace_credential_grant(
               connect_credential,
               {:person, person.id},
               %{
                 api_key: "scheduled-expiry-key",
                 expires_at: DateTime.add(DateTime.utc_now(), 2, :second)
               }
             )

    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)
    actor = %{person: %{id: person.id}}

    assert_successful_execution(configured_agent, actor, person)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer scheduled-expiry-key"]}

    [server_pid] = agent_server_pids(configured_agent)
    server_ref = Process.monitor(server_pid)
    assert_receive {:DOWN, ^server_ref, :process, ^server_pid, _reason}, 5_000

    assert_failed_execution(
      configured_agent,
      actor,
      person,
      %{credential_id: connect_credential.id, reason: :credential_expired}
    )

    refute_received {:llm_authorization, ^endpoint, _authorization}
  end

  test "authentication expiry fences only the matching runtime incarnation before cold resolution" do
    {configured_agent, credential, endpoint} = credential_agent_fixture(self())
    connect_credential = Connect.get_credential!(credential.connect_credential_id)
    {:ok, person} = People.create_person(%{full_name: "Expiring Credential Person"})

    assert {:ok, connect_credential} =
             Connect.update_credential(connect_credential, %{
               personal_credential_policy: :optional
             })

    assert {:ok, personal_dto} =
             Connect.replace_credential_grant(
               connect_credential,
               {:person, person.id},
               %{
                 api_key: "expiring-person-key",
                 expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
               }
             )

    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    actor = %{person: %{id: person.id}}
    assert_successful_execution(configured_agent, actor, person)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer expiring-person-key"]}

    [server_id] = server_ids_for(configured_agent.name)
    [server_pid] = agent_server_pids(configured_agent)
    server_ref = Process.monitor(server_pid)
    stale_pid = spawn(fn -> :ok end)

    send(ServerManager, {:expire_authentication, server_id, stale_pid})
    _state_after_stale_callback = :sys.get_state(ServerManager)
    assert Process.alive?(server_pid)

    assert_successful_execution(configured_agent, actor, person)
    assert_receive {:llm_authorization, ^endpoint, ["Bearer expiring-person-key"]}

    expired_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    personal_grant = Repo.get!(Grant, personal_dto.grant_id)
    Repo.update!(Ecto.Changeset.change(personal_grant, expires_at: expired_at))

    :sys.replace_state(ServerManager, fn state ->
      update_in(state, [:credential_dependencies, server_id], fn dependency ->
        %{dependency | expires_at: expired_at}
      end)
    end)

    send(ServerManager, {:expire_authentication, server_id, server_pid})
    assert_receive {:DOWN, ^server_ref, :process, ^server_pid, _reason}, 5_000

    assert_failed_execution(
      configured_agent,
      actor,
      person,
      %{credential_id: connect_credential.id, reason: :credential_expired}
    )

    refute_received {:llm_authorization, ^endpoint, _headers}
  end

  # Base server ids in the Jido agent registry, shaped "<agent_name>:<scope>".
  # The react strategy also registers "<server_id>/react_worker" children; those
  # are excluded so we assert on the spawned agent server itself.
  defp spawned_server_ids do
    Zaq.Agent.Jido
    |> Jido.registry_name()
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.reject(&String.contains?(&1, "/"))
  end

  defp server_ids_for(agent_name) do
    Enum.filter(spawned_server_ids(), &String.starts_with?(&1, agent_name <> ":"))
  end

  test "concurrent messages on the same server scope are rejected with :busy" do
    test_pid = self()

    # Atomic counter — only the FIRST request to land holds the lock open long
    # enough for the rest to pile up against the same Jido agent process.
    # (`Agent` is aliased to `Zaq.Agent` in this module, so we use :atomics.)
    counter = :atomics.new(1, [])

    handler = fn conn, _body ->
      n = :atomics.add_get(counter, 1, 1)
      if n == 1, do: Process.sleep(800)
      send(test_pid, {:llm_hit, n})
      {200, streamed_reply(conn.request_path, "Yo", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Busy Cred #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Busy Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "Reply with Yo.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    # Same channel + no :scope override => ONE server_id => ONE process.
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    # Fire 8 concurrently against the SAME agent/scope.
    results =
      1..8
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Executor.run(incoming,
            agent_id: to_string(configured_agent.id),
            event: execution_event()
          )
        end)
      end)
      |> Task.await_many(5_000)

    errored = Enum.filter(results, & &1.metadata.error)
    ok = Enum.reject(results, & &1.metadata.error)

    # The busy ones never reach the LLM; only the winner(s) hit the stub.
    assert errored != [], "expected at least one :busy rejection"
    assert ok != [], "expected at least one request to win the lock"

    # Naming proof for the collision: all 8 derive the SAME scope (no
    # conversation/person/run_id ⇒ "anonymous"), so they collapse onto a SINGLE
    # spawned server `<name>:anonymous` — which is exactly why the overlap is
    # rejected as :busy rather than fanning out to distinct servers.
    assert server_ids_for(configured_agent.name) == ["#{configured_agent.name}:anonymous"]
  end

  test "runs catalog-only provider via openai runtime fallback" do
    handler = fn conn, body ->
      payload = Jason.decode!(body)
      assert payload["model"] == "deepseek/deepseek-r1-0528"

      {200, streamed_reply(conn.request_path, "Yo", "deepseek/deepseek-r1-0528")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Novita Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "novita_ai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Novita Integration Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a helper. Reply with Yo.",
        model: "deepseek/deepseek-r1-0528",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming, agent_id: to_string(configured_agent.id), event: execution_event())

    assert is_binary(outgoing.body)
    assert outgoing.metadata.error == false
    assert outgoing.metadata.configured_agent_id == configured_agent.id
    assert outgoing.metadata.configured_agent_name == configured_agent.name

    assert_receive {:openai_request, "POST", path, "", _body}, 1_000
    assert path in ["/v1/responses", "/v1/chat/completions"]
  end

  test "sends selected file tools in runtime LLM request" do
    handler = fn conn, body ->
      payload = Jason.decode!(body)

      assert is_list(payload["tools"])

      assert Enum.any?(payload["tools"], fn tool ->
               Map.get(tool, "name") == "sleep_action" or
                 get_in(tool, ["function", "name"]) == "sleep_action"
             end)

      {200, streamed_reply(conn.request_path, "Tool configured", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "OpenAI Tool Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Tool Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You can read files when needed.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["basic.sleep"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming, agent_id: to_string(configured_agent.id), event: execution_event())

    assert is_binary(outgoing.body)
    assert outgoing.metadata.error == false
    assert outgoing.metadata.configured_agent_id == configured_agent.id

    assert_receive {:openai_request, "POST", "/v1/responses", "", _body}, 1_000
  end

  test "executes with updated config after agent update" do
    prompt_v1 = "You are prompt v1. Always answer one."
    prompt_v2 = "You are prompt v2. Always answer two."

    handler = fn conn, _body ->
      {200, streamed_reply(conn.request_path, "ok", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "OpenAI Update Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Update Agent #{System.unique_integer([:positive])}",
        description: "",
        job: prompt_v1,
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    first_outgoing =
      Executor.run(incoming, agent_id: to_string(configured_agent.id), event: execution_event())

    assert first_outgoing.metadata.error == false

    assert_receive {:openai_request, "POST", _path1, "", body1}, 1_000
    assert String.contains?(body1, prompt_v1)

    update_event =
      Event.new(
        %{id: configured_agent.id, attrs: %{job: prompt_v2}},
        :agent,
        opts: [action: :configured_agent_updated]
      )

    assert {:ok, %{agent: updated_agent}} = NodeRouter.dispatch(update_event).response

    second_outgoing =
      Executor.run(incoming, agent_id: to_string(updated_agent.id), event: execution_event())

    assert second_outgoing.metadata.error == false

    assert_receive {:openai_request, "POST", _path2, "", body2}, 1_000
    assert String.contains?(body2, prompt_v2)
  end

  test "routes to answering path when no agent_id is provided" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    # nil agent_id → answering configured agent; ServerManager spawns a real server.
    # Since there is no LLM configured in test env, the run will error gracefully.
    outgoing = Executor.run(incoming, event: execution_event())

    assert %Zaq.Engine.Messages.Outgoing{} = outgoing
  end

  test "returns graceful error when selected agent is inactive" do
    credential =
      ai_credential_fixture(%{
        name: "Inactive Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Inactive Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are disabled.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: false,
        advanced_options: %{}
      })

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming, agent_id: to_string(configured_agent.id), event: execution_event())

    assert outgoing.metadata.error == true
    assert outgoing.metadata.reason == ":inactive_agent"
    assert outgoing.body =~ "something went wrong"
  end

  test "returns graceful error when selected agent does not exist" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}
    outgoing = Executor.run(incoming, agent_id: "999999999", event: execution_event())

    assert outgoing.metadata.error == true
    assert outgoing.metadata.reason == ":agent_not_found"
    assert outgoing.body =~ "something went wrong"
  end

  test "run/1 with no opts routes to answering path" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "bo-test",
      provider: :web,
      person: %{id: 42}
    }

    outgoing = Executor.run(incoming)

    assert %Zaq.Engine.Messages.Outgoing{} = outgoing
  end

  test "normalizes nested result answer maps" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming,
        event: execution_event(),
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryResult
      )

    assert outgoing.body == "from-result"
    assert outgoing.metadata.error == false
  end

  test "normalizes answer key maps" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming,
        event: execution_event(),
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryAnswer
      )

    assert outgoing.body == "from-answer"
    assert outgoing.metadata.error == false
  end

  test "falls back to inspect for non-string answers" do
    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming,
        event: execution_event(),
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryOther
      )

    assert outgoing.body == "%{unexpected: 123}"
    assert outgoing.metadata.error == false
  end

  test "returns graceful error when provider call fails" do
    handler = fn _conn, _body ->
      {500, %{error: %{message: "upstream failure"}}}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "OpenAI Failure Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Executor Failure Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a helper.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming, agent_id: to_string(configured_agent.id), event: execution_event())

    assert outgoing.metadata.error == true
    assert outgoing.body =~ "temporarily unavailable"
    assert_receive {:openai_request, "POST", "/v1/responses", "", _body}, 1_000
  end

  test "suppresses stream error only after answer content was already delivered" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "bo-test",
      provider: :web,
      metadata: %{status_message_id: "msg-123"}
    }

    outgoing =
      Executor.run(incoming,
        event: execution_event(),
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryStreamErrorAfterContent
      )

    assert outgoing.metadata.error == false
    assert outgoing.metadata[:suppressed] == true
    assert outgoing.body == ""
  end

  test "surfaces stream error when status_message_id is set but no content was delivered" do
    # Regression: a budget/rate-limit error fails on the very first token. A
    # status placeholder exists, but the user saw nothing — so the error must be
    # surfaced, not suppressed into an empty bubble.
    incoming = %Incoming{
      content: "hello",
      channel_id: "bo-test",
      provider: :web,
      metadata: %{status_message_id: "msg-123"}
    }

    outgoing =
      Executor.run(incoming,
        event: execution_event(),
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryStreamError
      )

    assert outgoing.metadata.error == true
    assert outgoing.body =~ "something went wrong"
    refute outgoing.metadata[:suppressed] == true
  end

  test "surfaces stream error when no status_message_id is set in incoming metadata" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "bo-test",
      provider: :web
    }

    outgoing =
      Executor.run(incoming,
        event: execution_event(),
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryStreamError
      )

    assert outgoing.metadata.error == true
    assert outgoing.body =~ "something went wrong"
  end

  test "telemetry_dimensions silently drops unknown string keys in incoming metadata" do
    unknown_key = "definitely_not_an_existing_atom_zxqy_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    incoming = %Incoming{
      content: "hi",
      channel_id: "ch",
      provider: :web,
      metadata: %{
        "telemetry_dimensions" => %{
          unknown_key => "value",
          "channel_type" => "mattermost"
        }
      }
    }

    Sandbox.allow(Repo, self(), Process.whereis(Buffer))
    Buffer.flush()
    Repo.delete_all(Point)

    outgoing =
      Executor.run(incoming,
        event: execution_event(),
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryAnswer
      )

    assert outgoing.metadata.error == false
    assert :ok = Buffer.flush()

    [dimensions] =
      Repo.all(
        from p in Point,
          where: p.metric_key == "qa.custom_agent.execution.complete",
          select: p.dimensions
      )

    assert dimensions["channel_type"] == "mattermost"
    refute Map.has_key?(dimensions, unknown_key)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end
  end

  test "telemetry_dimensions accepts atom pairs and ignores malformed entries" do
    incoming = %Incoming{
      content: "hi",
      channel_id: "ch",
      provider: :web,
      metadata: %{
        "telemetry_dimensions" => [{:channel_type, "mattermost"}, :malformed_entry]
      }
    }

    Sandbox.allow(Repo, self(), Process.whereis(Buffer))
    Buffer.flush()
    Repo.delete_all(Point)

    outgoing =
      Executor.run(incoming,
        event: execution_event(),
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryAnswer
      )

    assert outgoing.metadata.error == false
    assert :ok = Buffer.flush()

    [dimensions] =
      Repo.all(
        from p in Point,
          where: p.metric_key == "qa.custom_agent.execution.complete",
          select: p.dimensions
      )

    assert dimensions["channel_type"] == "mattermost"
    assert dimensions["execution_path"] == "custom_agent"
    refute Map.has_key?(dimensions, "malformed_entry")
  end

  test "attachment metadata falls back to canonical values when runtime storage is unavailable" do
    handle = "signed-handle-#{System.unique_integer([:positive])}"
    raw_secret = "provider-secret-#{System.unique_integer([:positive])}"

    attachment = %Record{
      id: "record-123",
      kind: :file,
      name: "report.pdf",
      mime_type: "application/pdf",
      materialization_handle: handle,
      raw: %{secret: raw_secret}
    }

    incoming = %Incoming{
      content: "summarize this",
      channel_id: "ch",
      provider: :web,
      attachments: [attachment]
    }

    runtime_store_name = Jido.runtime_store_name(Zaq.Agent.Jido)
    runtime_store_pid = Process.whereis(runtime_store_name)
    assert is_pid(runtime_store_pid)
    Process.unregister(runtime_store_name)

    try do
      outgoing =
        Executor.run(incoming,
          event: execution_event(),
          agent_id: "stub",
          agent_module: StubAgent,
          server_manager_module: StubServerManager,
          factory_module: StubFactoryAttachment
        )

      assert outgoing.metadata.error == false
      assert_receive {:executor_question, question}
      [_prompt, encoded] = String.split(question, "Attachments:\n", parts: 2)
      [metadata] = Jason.decode!(encoded)
      assert metadata["id"] == "record-123"
      assert metadata["name"] == "report.pdf"
      assert metadata["mime_type"] == "application/pdf"
      assert metadata["materialization_handle"] == handle
      refute encoded =~ raw_secret
      refute encoded =~ "mat_"
    after
      if Process.whereis(runtime_store_name) == nil and Process.alive?(runtime_store_pid) do
        Process.register(runtime_store_pid, runtime_store_name)
      end
    end
  end

  defp credential_agent_fixture(test_pid) do
    handler = fn conn, _body ->
      request_endpoint = "http://#{conn.host}:#{conn.port}/v1"

      send(
        test_pid,
        {:llm_authorization, request_endpoint, Plug.Conn.get_req_header(conn, "authorization")}
      )

      {200, streamed_reply(conn.request_path, "Authorized", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "org-key"
      })

    {:ok, configured_agent} = create_http_agent(credential)
    {configured_agent, credential, endpoint}
  end

  defp stop_agent_servers(configured_agent) do
    registry = Jido.registry_name(Zaq.Agent.Jido)

    monitors =
      configured_agent.name
      |> server_ids_for()
      |> Enum.flat_map(&Registry.lookup(registry, &1))
      |> Enum.map(fn {pid, _value} -> Process.monitor(pid) end)

    assert :ok = ServerManager.stop_server(configured_agent)

    Enum.each(monitors, fn ref ->
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
    end)
  end

  defp agent_server_pids(configured_agent) do
    registry = Jido.registry_name(Zaq.Agent.Jido)

    configured_agent.name
    |> server_ids_for()
    |> Enum.flat_map(&Registry.lookup(registry, &1))
    |> Enum.map(&elem(&1, 0))
  end

  defp capture_credential_notification(credential_id, mutation) do
    CredentialMutationJob.capture!(credential_id, mutation)
  end

  defp deliver_credential_notification(job) do
    assert :ok = CredentialMutationJob.deliver!(job, "credential-runtime-test")
  end

  defp create_http_agent(credential) do
    Agent.create_agent(%{
      name: "Credential HTTP Agent #{System.unique_integer([:positive, :monotonic])}",
      description: "",
      job: "Reply with Authorized.",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      strategy: "react",
      enabled_tool_keys: [],
      conversation_enabled: false,
      active: true,
      advanced_options: %{"stream" => false}
    })
  end

  defp assert_successful_execution(configured_agent, actor, person \\ nil) do
    incoming = %Incoming{
      content: "credential check",
      channel_id: "credential-http-test",
      provider: :web,
      person: person
    }

    outgoing =
      Executor.run(incoming,
        agent_id: to_string(configured_agent.id),
        event: execution_event(actor)
      )

    assert outgoing.metadata.error == false
    assert is_binary(outgoing.body)
    outgoing
  end

  defp assert_failed_execution(configured_agent, actor, person, expected_reason) do
    incoming = %Incoming{
      content: "credential check",
      channel_id: "credential-http-test",
      provider: :web,
      person: person
    }

    outgoing =
      Executor.run(incoming,
        agent_id: to_string(configured_agent.id),
        event: execution_event(actor)
      )

    assert outgoing.metadata.error == true

    if expected_reason do
      assert outgoing.metadata.reason == inspect(expected_reason)
    end

    outgoing
  end

  defp drain_messages(tag, acc \\ []) do
    receive do
      {^tag, value} -> drain_messages(tag, [value | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp execution_event(actor \\ %{kind: :anonymous, subject: "executor-integration-test"}) do
    Event.new(nil, :agent, actor: actor)
  end

  defp streamed_reply("/v1/chat/completions", text, model) do
    chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-test",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]
      })

    done_chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-test",
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
          "id" => "resp_test",
          "model" => model,
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
        }
      })

    [
      "event: response.output_text.delta\n",
      "data: #{delta_event}\n\n",
      "event: response.completed\n",
      "data: #{completed_event}\n\n"
    ]
    |> IO.iodata_to_binary()
  end
end
