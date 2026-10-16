defmodule Zaq.Agent.ExecutorIntegrationTest do
  use Zaq.DataCase, async: false

  import Ecto.Query
  import Zaq.SystemConfigFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.People
  alias Zaq.Agent
  alias Zaq.Agent.Answering
  alias Zaq.Agent.Api
  alias Zaq.Agent.Executor
  alias Zaq.Agent.Factory
  alias Zaq.Agent.HistorySync
  alias Zaq.Agent.RequestControl
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Telemetry.Buffer
  alias Zaq.Engine.Telemetry.Point
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.Repo
  alias Zaq.System.AIProviderCredential
  alias Zaq.Utils.DateUtils

  alias Zaq.TestSupport.{
    ConnectOAuthAttemptConfig,
    ConnectOAuthAttemptHTTP,
    CredentialMutationJob,
    IntegrationAgent,
    OpenAIStub
  }

  setup {Req.Test, :verify_on_exit!}

  test "model input uses persisted message author and time instead of processing-time hints" do
    {configured, _credential, _endpoint} = credential_agent_fixture(self())
    on_exit(fn -> _ = ServerManager.stop_server(configured) end)
    {:ok, person} = People.create_person(%{full_name: "Original name"})

    for source_time <- [~U[2026-01-02 03:04:05Z], nil] do
      incoming =
        Incoming.new(%{
          provider: :web,
          channel_id: "bo",
          author_id: "person",
          person: person,
          content: "Persisted body",
          routing_context: %{provider_sent_at: source_time}
        })

      assert {:ok, binding} = Conversations.admit_incoming(incoming)

      assert {:ok, _} =
               People.update_person(People.get_person!(person.id), %{full_name: "Current name"})

      stored = Repo.get!(Message, binding.user_message_id)

      later = %{
        incoming
        | author_name: "Unverified channel name",
          routing_context: %{
            incoming.routing_context
            | provider_sent_at: ~U[2026-10-15 09:00:00Z]
          }
      }

      outgoing =
        Executor.run(later,
          agent_id: configured.id,
          actor: %{person: %{id: person.id}},
          conversation_binding: binding
        )

      assert outgoing.metadata.error == false
      assert_receive {:openai_request, "POST", _path, _authorization, body}, 5_000

      time_header =
        if source_time,
          do: "Sent at: 2026-01-02 03:04:05Z",
          else: "Recorded at: #{DateUtils.format_ts(stored.inserted_at)}"

      expected =
        "Author: \"Current name\" [person:#{person.id}]\n#{time_header}\nMessage:\nPersisted body"

      assert body =~ Jason.encode!(expected)
      refute body =~ "2026-10-15 09:00:00Z"
      assert Repo.get!(Message, stored.id).content == "Persisted body"
    end
  end

  defmodule StubAgent do
    def get_active_agent(_agent_id), do: {:ok, %{id: 77, name: "Stub Agent"}}
  end

  defmodule StubServerManager do
    def ensure_server(_configured_agent, _server_id, _context, opts) do
      _actor = Keyword.fetch!(opts, :actor)
      {:ok, self()}
    end

    def stop_server_if_current(configured_agent, server_id, runtime_pid) do
      send(self(), {:stopped_failed_runtime, configured_agent.id, server_id, runtime_pid})
      :ok
    end
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

  defmodule StubFactoryUsage do
    def ask_with_config(_server, _content, _configured_agent, _opts \\ []) do
      model = Process.get(:executor_usage_model, "openai:gpt-4.1-mini")

      call_data = %{usage: %{input_tokens: 11, output_tokens: 7, total_tokens: 18}}
      call_data = if is_nil(model), do: call_data, else: Map.put(call_data, :model, model)

      {:ok,
       %{
         request: :request,
         events: [
           %{
             id: "usage-event",
             kind: :llm_completed,
             at_ms: 1,
             request_id: "req-usage",
             run_id: "run-usage",
             llm_call_id: "call-usage",
             data: call_data
           },
           %{
             kind: :request_completed,
             at_ms: 2,
             data: %{
               result: "done",
               usage: %{input_tokens: 11, output_tokens: 7, total_tokens: 18}
             }
           }
         ]
       }}
    end

    def answering_configured_agent, do: %{id: :answering, name: "answering"}
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

  defmodule StubFactoryStreamErrorWithUsage do
    def ask_with_config(_server, _content, _configured_agent, _opts \\ []) do
      {:ok,
       %{
         request: :request,
         events: [
           %{
             id: "completed-call",
             kind: :llm_completed,
             at_ms: 1,
             request_id: "req-failed",
             run_id: "run-failed",
             llm_call_id: "call-failed",
             data: %{
               model: "openai:gpt-4.1-mini",
               usage: %{input_tokens: 4, output_tokens: 2, total_tokens: 6}
             }
           },
           %{
             kind: :request_failed,
             at_ms: 2,
             data: %{
               error: ReqLLM.Error.API.Stream.exception(reason: "later call failed", cause: nil)
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

  defmodule StubFactoryStreamErrorAfterBlankContent do
    def ask_with_config(_server, _content, _configured_agent, _opts \\ []) do
      delta = Process.get(:blank_stream_delta)

      events =
        if is_binary(delta) do
          [%{kind: :llm_delta, at_ms: 1, data: %{chunk_type: :content, delta: delta}}]
        else
          []
        end

      {:ok,
       %{
         request: :request,
         events:
           events ++
             [
               %{
                 kind: :request_failed,
                 at_ms: 2,
                 data: %{
                   error: ReqLLM.Error.API.Stream.exception(reason: "stream closed", cause: nil)
                 }
               }
             ]
       }}
    end

    def answering_configured_agent, do: %{id: :answering, name: "answering"}
  end

  defmodule ClosedControlFactory do
    def steer(_runtime, content, _opts) do
      send(Process.get(:followup_owner), {:native_control_refused, content})
      Process.get(:control_outcome, {:error, {:rejected, :idle}})
    end
  end

  defmodule FencedHandleFactory do
    def ask_with_config(runtime, content, configured_agent, opts) do
      result = Factory.ask_with_config(runtime, content, configured_agent, opts)
      {server_id, ^runtime, token} = opts[:tool_context].execution_history.lease_ref
      send(Process.get(:followup_owner), {:native_handle_fenced, runtime, server_id})
      :ok = ServerManager.abort_history_request(server_id, token)
      result
    end
  end

  defmodule BusyAfterLeaseFactory do
    def ask_with_config(_runtime, _content, _configured_agent, _opts) do
      send(Process.get(:followup_owner), :busy_factory_reached)
      {:error, {:rejected, :busy}}
    end
  end

  defmodule FollowupBoundaryRouter do
    def dispatch(%Event{opts: [action: :send_typing]} = event),
      do: %{event | response: :ok}

    def dispatch(%Event{opts: [action: :prepare_execution_followup, confidential: true]} = event) do
      send(Process.get(:followup_owner), {:prepare_followup, event.request})

      case Process.get(:followup_boundary_response, :delegate) do
        :delegate -> NodeRouter.dispatch(event)
        response -> %{event | response: response}
      end
    end

    def dispatch(event), do: NodeRouter.dispatch(event)
  end

  for {outcome, expected} <- [
        {{:ok, :already_prepared}, :followup_already_prepared},
        {{:error, :followup_preparation_failed}, :followup_preparation_failed},
        {:malformed, :history_handoff_unavailable}
      ] do
    test "canonical followup preparation #{inspect(outcome)} stops without delivery" do
      %{event: event, release: release, root: root, binding: binding} =
        canonical_followup_fixture()

      test_pid = self()

      followup =
        Task.async(fn ->
          Sandbox.allow(Repo, test_pid, self())
          Process.put(:followup_owner, test_pid)
          Process.put(:followup_boundary_response, unquote(Macro.escape(outcome)))
          Api.handle_event(event, :run_pipeline, nil)
        end)

      expected_control = followup_prompt(binding)
      assert_receive {:native_control_refused, ^expected_control}, 5_000
      send(release, :release_root_llm)
      assert %Outgoing{body: "Root answer", metadata: %{error: false}} = Task.await(root, 10_000)
      assert_receive {:openai_request, "POST", "/v1/responses", "", _}, 5_000
      result = Task.await(followup, 10_000)

      assert_receive {:prepare_followup, %{content: "Followup input"}}, 5_000
      assert result.response == {:error, unquote(expected)}
      assert result.next_hop == nil
      refute result.response == {:ok, :queued}
      refute_received {:openai_request, "POST", "/v1/responses", "", _}
      original = Repo.get!(ExecutionRecord, binding.execution_id)
      assert original.status == "unconsumed"
      assert original.public_answer_message_id == nil
      assert Repo.get_by(ExecutionRecord, recovered_from_execution_id: original.id) == nil
    end
  end

  test "canonical followup recovers through real Executor and finalizes only its new root" do
    %{event: event, release: release, root: root, binding: binding} = canonical_followup_fixture()
    owner = self()

    followup =
      Task.async(fn ->
        Sandbox.allow(Repo, owner, self())
        Process.put(:followup_owner, owner)
        Api.handle_event(event, :run_pipeline, nil)
      end)

    expected_control = followup_prompt(binding)
    assert_receive {:native_control_refused, ^expected_control}, 5_000
    send(release, :release_root_llm)
    assert %Outgoing{body: "Root answer", metadata: %{error: false}} = Task.await(root, 10_000)
    assert_receive {:openai_request, "POST", "/v1/responses", "", _}, 5_000
    assert_receive {:prepare_followup, %{content: "Followup input"}}, 5_000

    result = Task.await(followup, 10_000)
    assert %Outgoing{body: "Followup answer", metadata: %{error: false}} = result.response
    assert result.next_hop != nil
    assert_receive {:openai_request, "POST", "/v1/responses", "", _}, 5_000

    original = Repo.get!(ExecutionRecord, binding.execution_id)
    assert original.public_answer_message_id == nil
    assert original.status == "unconsumed"

    recovered = Repo.get_by!(ExecutionRecord, recovered_from_execution_id: original.id)
    assert recovered.status == "completed"
    assert Repo.get!(Message, recovered.public_answer_message_id).content == "Followup answer"
  end

  test "canonical control rejection returns its exact error without a second answer" do
    %{event: event, release: release, root: root, binding: binding} = canonical_followup_fixture()
    owner = self()

    rejected =
      Task.async(fn ->
        Sandbox.allow(Repo, owner, self())
        Process.put(:followup_owner, owner)
        Process.put(:control_outcome, {:error, :control_unavailable})
        Api.handle_event(event, :run_pipeline, nil)
      end)

    expected_control = followup_prompt(binding)
    assert_receive {:native_control_refused, ^expected_control}, 5_000
    result = Task.await(rejected, 10_000)
    assert result.response == {:error, :control_unavailable}
    assert result.next_hop == nil
    refute_received {:prepare_followup, _}

    send(release, :release_root_llm)
    assert %Outgoing{body: "Root answer", metadata: %{error: false}} = Task.await(root, 10_000)
    assert_receive {:openai_request, "POST", "/v1/responses", "", _}, 5_000
    refute_received {:openai_request, "POST", "/v1/responses", "", _}
    assert Repo.get!(ExecutionRecord, binding.execution_id).public_answer_message_id == nil
  end

  test "active canonical control refuses another Person and a different execution scope" do
    %{event: event, release: release, root: root, binding: binding} = canonical_followup_fixture()
    actor = event.actor

    assert {:ok, projection} =
             HistorySync.execution_admission([], binding, actor, event.request.content)

    scope = "history:#{projection.transcript_id}:person:#{actor.person.id}"
    assert {:ok, {request_id, _}} = RequestControl.find_native_request(scope, actor)
    {:ok, other} = People.create_person(%{full_name: "Different Person"})

    for {control_actor, requested_scope, expected} <- [
          {%{person: %{id: other.id}}, scope, :not_found},
          {actor, "#{scope}:other", :scope_conflict}
        ] do
      control =
        Event.new(
          %{
            request_id: request_id,
            content: "must not enter the root",
            execution_scope: requested_scope
          },
          :agent,
          actor: control_actor,
          opts: [action: :steer_request, node_router: FollowupBoundaryRouter]
        )

      result = Api.handle_event(control, :steer_request, nil)
      assert result.response == {:error, expected}
      assert result.next_hop == control.next_hop
    end

    refute_received {:native_control_refused, _}
    send(release, :release_root_llm)
    assert %Outgoing{body: "Root answer", metadata: %{error: false}} = Task.await(root, 10_000)
    assert_receive {:openai_request, "POST", "/v1/responses", "", _}, 5_000
    assert Repo.get!(ExecutionRecord, binding.execution_id).status == "pending"
  end

  test "fencing a canonical lease after Factory returns a handle fails before stream consumption" do
    %{event: event, release: release, root: root, binding: binding} = canonical_followup_fixture()
    send(release, :release_root_llm)
    assert %Outgoing{body: "Root answer", metadata: %{error: false}} = Task.await(root, 10_000)
    assert_receive {:openai_request, "POST", "/v1/responses", "", _}, 5_000

    Process.put(:followup_owner, self())

    outgoing =
      Executor.run(event.request,
        agent_id: event.assigns["agent_selection"]["agent_id"],
        conversation_binding: binding,
        actor: event.actor,
        person_id: event.actor.person.id,
        node_router: FollowupBoundaryRouter,
        factory_module: FencedHandleFactory
      )

    assert_received {:native_handle_fenced, old_runtime, server_id}
    assert outgoing.metadata.error == true
    refute outgoing.body == "Followup answer"
    assert Repo.get!(ExecutionRecord, binding.execution_id).public_answer_message_id == nil
    assert Jido.AgentServer.whereis(Jido.registry_name(Zaq.Agent.Jido), server_id) != old_runtime

    HistorySync.with_session(fn session ->
      recovered =
        Executor.run(event.request,
          history_session: session,
          agent_id: event.assigns["agent_selection"]["agent_id"],
          conversation_binding: binding,
          actor: event.actor,
          person_id: event.actor.person.id,
          node_router: FollowupBoundaryRouter
        )

      assert recovered.metadata.error == false
      assert recovered.body == "Followup answer"
      new_runtime = Jido.AgentServer.whereis(Jido.registry_name(Zaq.Agent.Jido), server_id)
      assert is_pid(new_runtime)
      refute new_runtime == old_runtime

      assert {:ok, persisted} =
               Conversations.finalize_incoming(
                 binding.user_message_id,
                 binding.finalization_token,
                 %{answer: recovered.body, usage: %{}, error: false},
                 actor: event.actor,
                 execution_id: binding.execution_id
               )

      assert :ok = HistorySync.complete(session, persisted, recovered)
    end)
  end

  test "a second canonical Executor waits for the root lease before Factory busy fallback" do
    %{event: event, release: release, root: root, binding: binding} = canonical_followup_fixture()
    owner = self()
    manager = Process.whereis(ServerManager)
    :erlang.trace(manager, true, [:receive, {:tracer, owner}])
    on_exit(fn -> if Process.alive?(manager), do: :erlang.trace(manager, false, [:receive]) end)

    second =
      Task.async(fn ->
        Sandbox.allow(Repo, owner, self())
        Process.put(:followup_owner, owner)

        Executor.run(event.request,
          agent_id: event.assigns["agent_selection"]["agent_id"],
          conversation_binding: binding,
          actor: event.actor,
          person_id: event.actor.person.id,
          node_router: FollowupBoundaryRouter,
          factory_module: BusyAfterLeaseFactory
        )
      end)

    assert_receive {:trace, ^manager, :receive,
                    {:"$gen_call", {second_pid, _}, {:begin_history_request, _, _, _}}}
                   when second_pid == second.pid,
                   5_000

    refute_received :busy_factory_reached
    send(release, :release_root_llm)
    assert %Outgoing{body: "Root answer", metadata: %{error: false}} = Task.await(root, 10_000)
    assert_receive :busy_factory_reached, 5_000
    busy = Task.await(second, 10_000)
    assert busy.metadata.error == true
    assert Repo.get!(ExecutionRecord, binding.execution_id).public_answer_message_id == nil
  end

  defp canonical_followup_fixture do
    owner = self()
    turn = :atomics.new(1, [])

    {child, endpoint} =
      OpenAIStub.server(
        fn conn, _body ->
          case :atomics.add_get(turn, 1, 1) do
            1 ->
              send(owner, {:root_llm_barrier, self()})

              receive do
                :release_root_llm ->
                  {200, streamed_reply(conn.request_path, "Root answer", "gpt-4.1-mini")}
              after
                10_000 -> flunk("root LLM barrier was not released")
              end

            2 ->
              {200, streamed_reply(conn.request_path, "Followup answer", "gpt-4.1-mini")}
          end
        end,
        owner
      )

    start_supervised!(child)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, configured} =
      Agent.create_agent(%{
        name: "Followup #{Ecto.UUID.generate()}",
        job: "Answer briefly",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        active: true
      })

    on_exit(fn -> _ = ServerManager.stop_server(configured) end)
    {:ok, person} = People.create_person(%{full_name: "Followup Person"})
    actor = %{person: %{id: person.id}}

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Followup room",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: "https://history.example.test",
        token: "test-token"
      })
      |> Repo.insert!()

    resource = ChannelHistoryResource.for("mattermost", config.id, "room")

    assert {:ok, _grant} =
             Permissions.grant(resource, %{person_id: person.id, access_rights: ["read"]})

    incoming = fn content ->
      Incoming.new(%{
        provider: :mattermost,
        person: person,
        author_id: "person",
        content: content,
        channel_id: "room",
        message_id: Ecto.UUID.generate(),
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })
      |> CommunicationBridge.put_conversation_identity()
    end

    first = incoming.("Root input")
    assert {:ok, _} = HistoryIngress.capture(first)
    assert {:ok, first_binding} = Conversations.admit_incoming(first)

    root =
      Task.async(fn ->
        Sandbox.allow(Repo, owner, self())

        HistorySync.with_session(fn session ->
          outgoing =
            Executor.run(first,
              history_session: session,
              conversation_binding: first_binding,
              agent_id: configured.id,
              person_id: person.id,
              actor: actor,
              node_router: FollowupBoundaryRouter
            )

          assert {:ok, persisted} =
                   Conversations.finalize_incoming(
                     first_binding.user_message_id,
                     first_binding.finalization_token,
                     %{answer: outgoing.body, usage: %{}, error: outgoing.metadata.error},
                     actor: actor,
                     execution_id: first_binding.execution_id
                   )

          assert :ok = HistorySync.complete(session, persisted, outgoing)
          outgoing
        end)
      end)

    assert_receive {:root_llm_barrier, release}, 5_000
    on_exit(fn -> send(release, :release_root_llm) end)

    second = incoming.("Followup input")
    assert {:ok, _} = HistoryIngress.capture(second)
    assert {:ok, second_binding} = Conversations.admit_incoming(second)

    event =
      Event.new(second, :agent,
        actor: actor,
        opts: [
          action: :run_pipeline,
          factory_module: ClosedControlFactory,
          node_router: FollowupBoundaryRouter
        ]
      )

    event = %{
      event
      | assigns: %{
          "agent_selection" => %{"agent_id" => configured.id},
          "conversation_binding" => second_binding
        }
    }

    %{event: event, release: release, root: root, binding: second_binding}
  end

  defp followup_prompt(binding) do
    message = Repo.get!(Message, binding.user_message_id)
    author_id = message.history_context["author_person_id"]
    name = Jason.encode!(People.get_person!(author_id).full_name)
    time = DateUtils.format_ts(message.inserted_at)

    "Author: #{name} [person:#{author_id}]\nRecorded at: #{time}\nMessage:\nFollowup input"
  end

  @tag :actual_request_identity
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

    correlation_id = "external-#{System.unique_integer([:positive])}"
    scope = "identity-#{System.unique_integer([:positive])}"

    incoming = %Incoming{
      content: "hello",
      channel_id: "bo-test",
      provider: :web,
      metadata: %{request_id: correlation_id}
    }

    outgoing =
      Executor.run(incoming,
        agent_id: to_string(configured_agent.id),
        scope: scope,
        event: execution_event()
      )

    assert is_binary(outgoing.body)
    assert outgoing.metadata.error == false
    assert outgoing.metadata.configured_agent_id == configured_agent.id
    assert outgoing.metadata.configured_agent_name == configured_agent.name

    assert_receive {:openai_request, "POST", "/v1/responses", "", _body}, 1_000

    runtime =
      Jido.AgentServer.whereis(
        Jido.registry_name(Zaq.Agent.Jido),
        "#{configured_agent.name}:#{scope}"
      )

    assert is_pid(runtime)
    assert {:ok, state} = Jido.AgentServer.state(runtime)
    [request_id] = Map.keys(state.agent.state.requests)
    refute request_id == correlation_id
    assert {:ok, %{status: :completed}} = Factory.request_state(runtime, request_id)
    assert {:error, :not_found} = Factory.request_state(runtime, correlation_id)
    assert :ets.whereis(:zaq_agent_request_observations) == :undefined

    # No application archive remains after teardown.
    assert :ok = ServerManager.stop_server(configured_agent)
    assert :ets.whereis(:zaq_agent_request_observations) == :undefined
  end

  test "canonical admission survives access loss before the real configured runtime is created" do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, _body ->
          {200, streamed_reply(conn.request_path, "Accepted answer", "gpt-4.1-mini")}
        end,
        self()
      )

    start_supervised!(child)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, configured} =
      Agent.create_agent(%{
        name: "Admitted #{Ecto.UUID.generate()}",
        job: "Answer briefly",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        active: true
      })

    {:ok, person} = People.create_person(%{full_name: "Admitted Person"})
    actor = %{person: %{id: person.id}}

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Admission",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: "https://history.example.test",
        token: "test-token"
      })
      |> Repo.insert!()

    incoming =
      Incoming.new(%{
        provider: :mattermost,
        person: person,
        author_id: "person",
        content: "Accepted input",
        channel_id: "room",
        message_id: Ecto.UUID.generate(),
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, _} = HistoryIngress.capture(incoming)
    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    resource = ChannelHistoryResource.for("mattermost", config.id, "room")

    assert {:ok, grant} =
             Permissions.grant(resource, %{person_id: person.id, access_rights: ["read"]})

    HistorySync.with_session(fn session ->
      opts = [
        history_session: session,
        conversation_binding: binding,
        agent_id: configured.id,
        person_id: person.id,
        actor: actor
      ]

      assert {:ok, projection} =
               HistorySync.execution_admission(opts, binding, actor, incoming.content)

      scope = "history:#{projection.transcript_id}:person:#{person.id}"

      assert Jido.AgentServer.whereis(
               Jido.registry_name(Zaq.Agent.Jido),
               "#{configured.name}:#{scope}"
             ) == nil

      assert :ok = Permissions.revoke(resource, grant)
      outgoing = Executor.run(incoming, opts)
      refute outgoing.metadata.error
      assert outgoing.body == "Accepted answer"
      assert_receive {:openai_request, "POST", _, _, _}, 5_000

      assert {:ok, persisted} =
               Conversations.finalize_incoming(
                 binding.user_message_id,
                 binding.finalization_token,
                 %{answer: outgoing.body, usage: %{}, error: false},
                 actor: actor,
                 execution_id: binding.execution_id
               )

      assert :ok = HistorySync.complete(session, persisted, outgoing)
      assert Repo.get!(ExecutionRecord, binding.execution_id).status == "completed"
      assert Repo.get!(Message, persisted.assistant_message_id).content == "Accepted answer"

      assert {:error, {:history_access_denied, _}} =
               HistorySync.execution_admission(
                 [history_session: make_ref()],
                 binding,
                 actor,
                 incoming.content
               )

      assert :ok = ServerManager.stop_server(configured)
    end)
  end

  test "revoked channel-history access before Executor admission is unauthorized without an LLM call" do
    owner = self()

    {child, endpoint} =
      OpenAIStub.server(
        fn conn, _body ->
          send(owner, {:unexpected_llm_request, conn.request_path})
          {200, streamed_reply(conn.request_path, "Unexpected answer", "gpt-4.1-mini")}
        end,
        self()
      )

    start_supervised!(child)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, configured} =
      Agent.create_agent(%{
        name: "Revoked admission #{Ecto.UUID.generate()}",
        job: "Answer briefly",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        active: true
      })

    on_exit(fn -> _ = ServerManager.stop_server(configured) end)

    {:ok, person} = People.create_person(%{full_name: "Revoked Admission Person"})
    actor = %{person: %{id: person.id}}

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Revoked Admission",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: "https://history.example.test",
        token: "test-token"
      })
      |> Repo.insert!()

    incoming =
      Incoming.new(%{
        provider: :mattermost,
        person: person,
        author_id: "person",
        content: "Must not execute",
        channel_id: "room",
        message_id: Ecto.UUID.generate(),
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, _} = HistoryIngress.capture(incoming)
    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    resource = ChannelHistoryResource.for("mattermost", config.id, "room")

    assert {:ok, grant} =
             Permissions.grant(resource, %{person_id: person.id, access_rights: ["read"]})

    assert :ok = Permissions.revoke(resource, grant)

    outgoing =
      Executor.run(incoming,
        conversation_binding: binding,
        agent_id: configured.id,
        person_id: person.id,
        actor: actor
      )

    assert outgoing.metadata.error
    assert outgoing.metadata.reason == ":unauthorized"
    assert Repo.get!(ExecutionRecord, binding.execution_id).status != "completed"
    refute_receive {:openai_request, _, _, _, _}, 100
    refute_received {:unexpected_llm_request, _}
  end

  test "a real busy rejection cannot stop the request already running in Jido" do
    owner = self()

    handler = fn conn, body ->
      request = Jason.decode!(body)
      assert request["model"] == "gpt-4.1-mini"
      send(owner, {:blocked_llm, self()})

      receive do
        :release_llm -> {200, streamed_reply(conn.request_path, "Owned answer", "gpt-4.1-mini")}
      after
        10_000 -> flunk("the test did not release its external LLM barrier")
      end
    end

    {child, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(child)
    scope = "busy-#{System.unique_integer([:positive])}"
    agent = IntegrationAgent.create!(endpoint, scope, "Answer briefly.", [])
    opts = [agent_id: to_string(agent.id), scope: scope, event: execution_event()]
    incoming = %Incoming{content: "first question", channel_id: "bo-test", provider: :web}
    first = Task.async(fn -> Executor.run(incoming, opts) end)
    assert_receive {:blocked_llm, http_worker}, 5_000
    on_exit(fn -> send(http_worker, :release_llm) end)

    runtime =
      Jido.AgentServer.whereis(Jido.registry_name(Zaq.Agent.Jido), "#{agent.name}:#{scope}")

    assert is_pid(runtime)
    second = Executor.run(%{incoming | content: "second question"}, opts)
    assert second.metadata.error
    assert Process.alive?(runtime)

    assert Jido.AgentServer.whereis(Jido.registry_name(Zaq.Agent.Jido), "#{agent.name}:#{scope}") ==
             runtime

    refute_received {:blocked_llm, _}
    send(http_worker, :release_llm)
    answer = Task.await(first, 5_000)
    assert answer.metadata.error == false
    assert answer.body == "Owned answer"
    assert Process.alive?(runtime)
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

  test "a no-auth AI credential sends no authorization header to a local LLM endpoint" do
    test_pid = self()

    handler = fn conn, _body ->
      send(test_pid, {:no_auth_headers, Plug.Conn.get_req_header(conn, "authorization")})
      {200, streamed_reply(conn.request_path, "No auth", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, auth_kind: "none"})

    {:ok, configured_agent} =
      create_http_agent(credential, %{
        "stream" => false,
        "provider_options" => %{"openai_compatible_backend" => "ollama"}
      })

    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    assert_successful_execution(configured_agent, %{kind: :system, subject: "no-auth"})
    assert_receive {:no_auth_headers, []}
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

    assert outgoing.metadata.reason == ":personal_credential_required"
    refute outgoing.metadata.reason =~ to_string(connect_credential.id)

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
    assert [%{"type" => "content"}] = outgoing.metadata.trace
    assert_received {:stopped_failed_runtime, 77, _server_id, runtime_pid}
    assert is_pid(runtime_pid)
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

  test "nil and whitespace-only partial answers never suppress a stream failure" do
    incoming = %Incoming{
      content: "hello",
      channel_id: "bo-test",
      provider: :web,
      metadata: %{status_message_id: "status-placeholder"}
    }

    for delta <- [nil, "  \n  "] do
      Process.put(:blank_stream_delta, delta)

      outgoing =
        Executor.run(incoming,
          event: execution_event(),
          agent_id: "stub",
          agent_module: StubAgent,
          server_manager_module: StubServerManager,
          factory_module: StubFactoryStreamErrorAfterBlankContent
        )

      assert outgoing.metadata.error == true
      assert outgoing.body =~ "something went wrong"
      refute outgoing.metadata[:suppressed] == true
      assert_received {:stopped_failed_runtime, 77, _server_id, runtime_pid}
      assert is_pid(runtime_pid)
    end
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

  test "records completed logical calls when the overall request later fails" do
    incoming = %Incoming{content: "hi", channel_id: "ch", provider: :web}

    Sandbox.allow(Repo, self(), Process.whereis(Buffer))
    Buffer.flush()
    Repo.delete_all(Point)

    outgoing =
      Executor.run(incoming,
        event: execution_event(),
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryStreamErrorWithUsage
      )

    assert outgoing.metadata.error == true
    assert [%{llm_call_id: "call-failed", total_tokens: 6}] = outgoing.metadata.llm_calls
    assert outgoing.metadata.model == "openai:gpt-4.1-mini"
    assert outgoing.metadata.measurements["llm_call_count"] == 1
    assert outgoing.metadata.measurements["total_tokens"] == 6
    assert outgoing.metadata.trace == []
    assert outgoing.metadata.agent == %{id: 77, name: "Stub Agent"}
    assert :ok = Buffer.flush()

    assert Repo.one(
             from p in Point,
               where: p.metric_key == "qa.llm.tokens.total",
               select: {p.value, p.dimensions["model"]}
           ) == {6.0, "gpt-4.1-mini"}
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

  test "records per-call token usage with model, provider, person, agent and session dimensions" do
    {:ok, person} = People.create_person(%{full_name: "Telemetry Person"})

    incoming = %Incoming{
      content: "hi",
      channel_id: "ch",
      provider: :web,
      metadata: %{conversation_id: "conv-1", session_id: "session-1"}
    }

    Sandbox.allow(Repo, self(), Process.whereis(Buffer))
    Buffer.flush()
    Repo.delete_all(Point)

    outgoing =
      Executor.run(incoming,
        event: execution_event(%{person: %{id: person.id}}),
        agent_id: "stub",
        agent_module: StubAgent,
        server_manager_module: StubServerManager,
        factory_module: StubFactoryUsage
      )

    assert outgoing.metadata.error == false
    assert :ok = Buffer.flush()

    points =
      Repo.all(
        from p in Point,
          where: p.metric_key in ["qa.llm.call.count", "qa.llm.tokens.total"],
          order_by: p.metric_key
      )

    assert Enum.map(points, &{&1.metric_key, &1.value}) == [
             {"qa.llm.call.count", 1.0},
             {"qa.llm.tokens.total", 18.0}
           ]

    assert Enum.all?(points, fn point ->
             point.dimensions["llm_provider"] == "openai" and
               point.dimensions["model"] == "gpt-4.1-mini" and
               point.dimensions["person_id"] == to_string(person.id) and
               point.dimensions["actor_type"] == "person" and
               point.dimensions["conversation_id"] == "conv-1" and
               point.dimensions["session_id"] == "session-1" and
               point.dimensions["llm_usage_attribution"] == "v1" and
               point.dimensions["configured_agent_id"] == 77
           end)

    assert Repo.one(
             from p in Point,
               where: p.metric_key == "qa.tokens.total",
               select: p.dimensions["llm_usage_attribution"]
           ) == "v1"
  end

  test "normalizes LLM model and metadata telemetry dimensions at boundary values" do
    {configured_agent, _credential, _endpoint} = credential_agent_fixture(self())
    Sandbox.allow(Repo, self(), Process.whereis(Buffer))
    Buffer.flush()

    cases = [
      {
        "unqualified-model",
        %{"conversation_id" => "conv-unqualified", "session_id" => "session-ok"},
        "unqualified-model",
        "openai",
        "unqualified-model",
        "conv-unqualified",
        "session-ok"
      },
      {"openai:", %{}, "openai:", "openai", "openai:", nil, nil},
      {":x", %{}, ":x", "openai", ":x", nil, nil},
      {"missing-model", %{}, nil, "openai", nil, nil, nil},
      {
        "blank-dimensions",
        %{"conversation_id" => "", "session_id" => "session-kept"},
        "openai:gpt-4.1-mini",
        "openai",
        "gpt-4.1-mini",
        nil,
        "session-kept"
      }
    ]

    for {label, metadata, model, expected_provider, expected_model, expected_conversation,
         expected_session} <- cases do
      Process.put(:executor_usage_model, model)
      Buffer.flush()
      Repo.delete_all(Point)

      incoming = %Incoming{
        content: "hi",
        channel_id: "telemetry-#{label}",
        provider: :web,
        metadata: metadata
      }

      outgoing =
        Executor.run(incoming,
          event: execution_event(),
          agent_id: to_string(configured_agent.id),
          server_manager_module: StubServerManager,
          factory_module: StubFactoryUsage
        )

      assert outgoing.metadata.error == false
      assert :ok = Buffer.flush()

      assert [%Point{value: 1.0, dimensions: dimensions}] =
               Repo.all(from p in Point, where: p.metric_key == "qa.llm.call.count")

      assert dimensions["llm_provider"] == expected_provider, label

      if is_nil(expected_model) do
        refute Map.has_key?(dimensions, "model")
      else
        assert dimensions["model"] == expected_model, label
      end

      if is_nil(expected_conversation) do
        refute Map.has_key?(dimensions, "conversation_id")
      else
        assert dimensions["conversation_id"] == expected_conversation, label
      end

      if is_nil(expected_session) do
        refute Map.has_key?(dimensions, "session_id")
      else
        assert dimensions["session_id"] == expected_session, label
      end
    end
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

  defp create_http_agent(credential, advanced_options \\ %{"stream" => false}) do
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
      advanced_options: advanced_options
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
      public_reason =
        case expected_reason do
          %{reason: reason} -> reason
          reason -> reason
        end

      assert outgoing.metadata.reason == inspect(public_reason)

      if is_map(expected_reason) and expected_reason[:credential_id] do
        refute outgoing.metadata.reason =~ to_string(expected_reason.credential_id)
      end
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
