defmodule Zaq.Agent.RequestControlTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts.People
  alias Zaq.Agent.Api
  alias Zaq.Agent.{Factory, RequestControl, ServerManager}
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Engine.{ChannelConfig, Conversations, HistoryIngress}
  alias Zaq.Engine.Conversations.ExecutionRecord
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.Repo
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}

  defmodule ExitingFactory do
    def steer(_runtime, _content, _opts), do: exit(:runtime_gone)
    def inject(_runtime, _content, _opts), do: exit(:runtime_gone)
  end

  defmodule ControlledFactory do
    def steer(runtime, _content, opts), do: respond(runtime, opts)
    def inject(runtime, _content, opts), do: respond(runtime, opts)

    defp respond(runtime, opts) do
      send(Process.get(:request_control_test_owner), {:controlled, runtime, opts})
      Process.get(:request_control_factory_result, {:ok, :accepted})
    end
  end

  defmodule ControlledRouter do
    def dispatch(event) do
      send(Process.get(:request_control_test_owner), {:routed, event})
      response = Process.get({:request_control_router_response, event.opts[:action]})
      if response, do: %{event | response: response}, else: Zaq.NodeRouter.dispatch(event)
    end
  end

  setup do
    owner = self()

    handler = fn _conn, body ->
      request = Jason.decode!(body)
      send(owner, {:request_control_model_request, request, self()})

      receive do
        :release_request_control_model ->
          {200, MultiAgentOpenAIStub.text_sse("Done", request["model"])}
      after
        10_000 -> {200, MultiAgentOpenAIStub.text_sse("Done", request["model"])}
      end
    end

    {child, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(child)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, agent} = create_agent(credential.id, "Request control")
    actor = %{kind: :bo_user, subject: "request-control-owner"}
    scope = "request-control:#{Ecto.UUID.generate()}"
    assert {:ok, server} = ServerManager.ensure_server(agent, scope, nil, actor: actor)
    on_exit(fn -> ServerManager.stop_server(agent, scope) end)

    %{agent: agent, actor: actor, scope: scope, server: server, pid: GenServer.whereis(server)}
  end

  test "native control reports stale runtime when either Jido operation exits", ctx do
    assert {:ok, %{request: request}} = Factory.ask_with_config(ctx.server, "Question", ctx.agent)
    assert_receive {:request_control_model_request, _, worker}, 5_000
    on_exit(fn -> send(worker, :release_request_control_model) end)

    for action <- [:steer_request, :inject_request] do
      event =
        Event.new(%{request_id: request.id}, :agent,
          actor: ctx.actor,
          opts: [factory_module: ExitingFactory]
        )

      assert {:error, :stale_runtime} =
               RequestControl.control(event, request.id, "Correction", action, nil)
    end
  end

  test "two active configured agents in one principal scope are ambiguous without an agent filter",
       ctx do
    {:ok, second} = create_agent(ctx.agent.credential_id, "Second request control")
    second_id = "second-agent:#{ctx.scope}"

    assert {:ok, second_server} =
             ServerManager.ensure_server(second, second_id, nil,
               actor: ctx.actor,
               execution_scope: ctx.scope
             )

    refute GenServer.whereis(second_server) == ctx.pid
    on_exit(fn -> ServerManager.stop_server(second, second_id) end)

    assert {:ok, %{request: first_request}} =
             Factory.ask_with_config(ctx.server, "First", ctx.agent)

    assert_receive {:request_control_model_request, _, first_worker}, 5_000
    on_exit(fn -> send(first_worker, :release_request_control_model) end)

    assert {:ok, %{request: second_request}} =
             Factory.ask_with_config(second_server, "Second", second)

    assert_receive {:request_control_model_request, _, second_worker}, 5_000
    on_exit(fn -> send(second_worker, :release_request_control_model) end)

    assert first_request.id != second_request.id
    assert {:error, :ambiguous_request} = RequestControl.find_native_request(ctx.scope, ctx.actor)

    assert {:ok, {first_id, _}} =
             RequestControl.find_native_request(ctx.scope, ctx.actor, %{agent_id: ctx.agent.id})

    assert {:ok, {second_id, _}} =
             RequestControl.find_native_request(ctx.scope, ctx.actor, %{agent_id: second.id})

    assert first_id == first_request.id
    assert second_id == second_request.id
  end

  test "literal scope authorization allows the exact scope and rejects another", ctx do
    id = active_request(ctx)
    assert {:ok, state} = RequestControl.authorize(event(ctx, %{execution_scope: ctx.scope}), id)
    assert state.runtime_pid == ctx.pid

    assert {:error, :scope_conflict} =
             RequestControl.authorize(event(ctx, %{execution_scope: ctx.scope <> ":other"}), id)
  end

  test "noncanonical live controls use the exact active request without a receipt", ctx do
    id = active_request(ctx)
    Process.put(:request_control_test_owner, self())

    for action <- [:steer_request, :inject_request] do
      assert {:ok, :accepted} =
               RequestControl.control(
                 event(ctx, %{}, factory_module: ControlledFactory),
                 id,
                 "Correction",
                 action,
                 nil
               )

      assert_receive {:controlled, pid, opts}
      assert pid == ctx.pid
      assert opts[:expected_request_id] == id
      refute Keyword.has_key?(opts, :extra_refs)
    end
  end

  test "canonical Person runtime requires a binding and admission; denied admission never queues",
       ctx do
    {person_ctx, id} = canonical_active(ctx)
    %{root: root, scope: scope, actor: actor} = person_ctx
    Process.put(:request_control_test_owner, self())
    root_record = Repo.get_by!(ExecutionRecord, user_message_id: root.user_message_id)
    assert root_record.id == root.execution_id
    assert {:ok, state} = RequestControl.authorize(Event.new(%{}, :agent, actor: actor), id)
    assert state.execution_user_message_id == root.user_message_id
    assert state.execution_scope == scope
    assert state.runtime_pid == person_ctx.pid

    event = Event.new(%{}, :agent, actor: actor, opts: [node_router: ControlledRouter])

    assert {:error, :admission_required} =
             RequestControl.control(event, id, "Correction", :steer_request, nil)

    assert_receive {:routed, authorized}, 5_000
    assert authorized.opts[:action] == :authorize_execution_control
    refute_receive {:routed, %{request: %{closed_disposition: _}}}

    child = admitted_child(person_ctx, "denied correction")
    Process.put({:request_control_router_response, :admit_execution}, {:error, :unauthorized})

    assert {:error, :unauthorized} =
             RequestControl.control(event, id, "denied correction", :steer_request, child)

    assert_receive {:routed, admitted}
    assert admitted.opts[:action] == :admit_execution
    refute_receive {:routed, %{request: %{closed_disposition: _}}}
  end

  test "an authorized Person control rejects mismatched scope and fails closed on reauthorization",
       ctx do
    {person_ctx, id} = canonical_active(ctx)
    Process.put(:request_control_test_owner, self())
    actor = person_ctx.actor

    assert {:error, :scope_conflict} =
             RequestControl.authorize(
               Event.new(%{execution_scope: person_ctx.scope <> ":other"}, :agent, actor: actor),
               id
             )

    Process.put(
      {:request_control_router_response, :authorize_execution_control},
      {:error, :unauthorized}
    )

    event = Event.new(%{}, :agent, actor: actor, opts: [node_router: ControlledRouter])
    assert {:error, :unauthorized} = RequestControl.authorize(event, id)
    assert_receive {:routed, authorization}
    assert authorization.opts[:action] == :authorize_execution_control
    assert authorization.opts[:confidential] == true
    assert authorization.request.user_message_id == person_ctx.root.user_message_id
    assert authorization.request.execution_id == person_ctx.root.execution_id
    refute_receive {:controlled, _, _}
  end

  test "processing status does not treat a history lease without a native request as active",
       ctx do
    person_ctx = canonical_person(ctx)

    assert {:ok, lease} =
             ServerManager.begin_history_request(ctx.scope, person_ctx.pid, person_ctx.actor)

    assert :ok =
             ServerManager.bind_history_request(ctx.scope, lease.token, %{
               session: make_ref(),
               actor: person_ctx.actor,
               history: %{binding: person_ctx.root}
             })

    event =
      Event.new(%{}, :agent,
        actor: person_ctx.actor,
        opts: [confidential: true]
      )

    root_message_id = person_ctx.root.user_message_id

    assert %Event{response: {:ok, [%{user_message_id: ^root_message_id, status: :unknown}]}} =
             Api.handle_event(event, :processing_status, nil)
  end

  test "closed-before-accept returns exact followup binding only when requested", ctx do
    {person_ctx, id} = canonical_active(ctx)
    Process.put(:request_control_test_owner, self())
    receipt_id = Ecto.UUID.generate()

    Process.put(
      {:request_control_router_response, :queue_execution_input},
      {:error,
       {:closed_before_accept,
        %{
          refs: %{
            root_execution_id: person_ctx.root.execution_id,
            execution_id: receipt_id
          }
        }}}
    )

    for followup? <- [false, true] do
      child = admitted_child(person_ctx, "Closed correction #{followup?}")

      event =
        Event.new(%{}, :agent,
          actor: person_ctx.actor,
          opts: [node_router: ControlledRouter, factory_module: ControlledFactory]
        )

      result =
        RequestControl.control(event, id, "Closed correction #{followup?}", :steer_request, child,
          followup?: followup?
        )

      assert_receive {:routed, admitted}
      assert admitted.opts[:action] == :admit_execution
      assert admitted.opts[:confidential] == true
      assert admitted.request.binding == child
      assert_receive {:routed, queued}
      assert queued.opts[:action] == :queue_execution_input
      assert queued.opts[:confidential] == true
      assert queued.request.root_user_message_id == person_ctx.root.user_message_id
      assert queued.request.closed_disposition == followup?

      if followup? do
        assert {:followup, disposition} = result
        assert disposition.root_request_id == id
        assert disposition.root_user_message_id == person_ctx.root.user_message_id
        assert disposition.root_execution_id == person_ctx.root.execution_id
        assert disposition.receipt_execution_id == receipt_id
        assert disposition.runtime_pid == person_ctx.pid
        assert disposition.disposition == :closed_before_accept
      else
        assert {:error, {:closed_before_accept, _}} = result
      end

      refute_receive {:controlled, _, _}
    end
  end

  test "incoming canonical control propagates a queue failure instead of claiming an answer",
       ctx do
    {person_ctx, _id} = canonical_active(ctx)
    Process.put(:request_control_test_owner, self())

    Process.put(
      {:request_control_router_response, :queue_execution_input},
      {:error, :queue_denied}
    )

    input = incoming(person_ctx.info, "incoming-#{Ecto.UUID.generate()}", "Incoming correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    projection = %{kind: :canonical, transcript_id: person_ctx.transcript_id}

    event =
      Event.new(%{}, :agent,
        actor: person_ctx.actor,
        opts: [node_router: ControlledRouter, factory_module: ControlledFactory]
      )

    assert {:error, :queue_denied} =
             RequestControl.queue_incoming(event, input, projection, binding, ctx.agent.id)

    assert_receive {:routed, admitted}
    assert admitted.opts[:action] == :admit_execution
    assert_receive {:routed, queued}
    assert queued.opts[:action] == :queue_execution_input
    assert queued.request.closed_disposition == true
    refute_receive {:controlled, _, _}
  end

  test "incoming canonical control is not active while its history scope is retiring", ctx do
    {person_ctx, _id} = canonical_active(ctx)
    Process.put(:request_control_test_owner, self())

    child_input = incoming(person_ctx.info, "retiring-#{Ecto.UUID.generate()}", "Retiring input")
    assert {:ok, _} = HistoryIngress.capture(child_input)
    assert {:ok, binding} = Conversations.admit_incoming(child_input)

    assert :ok =
             ServerManager.retire_history_scope(%{
               transcript_id: person_ctx.transcript_id,
               person_id: person_ctx.person.id
             })

    event =
      Event.new(%{}, :agent,
        actor: person_ctx.actor,
        opts: [node_router: ControlledRouter, factory_module: ControlledFactory]
      )

    assert :not_active =
             RequestControl.queue_incoming(
               event,
               child_input,
               %{kind: :canonical, transcript_id: person_ctx.transcript_id},
               binding,
               ctx.agent.id
             )

    assert_receive {:routed, admitted}
    assert admitted.opts[:action] == :admit_execution
    assert admitted.opts[:confidential] == true
    refute_receive {:routed, _}
    refute_receive {:controlled, _, _}
  end

  test "incoming canonical control is ambiguous across two same-agent runtimes", ctx do
    {person_ctx, _id} = canonical_active(ctx)
    Process.put(:request_control_test_owner, self())

    second_server_id = "request-control-second:#{Ecto.UUID.generate()}"

    assert {:ok, projection} =
             Conversations.admit_execution(
               person_ctx.root,
               person_ctx.actor,
               "Root question"
             )

    assert {:ok, second_server} =
             ServerManager.ensure_server(ctx.agent, second_server_id, nil,
               actor: person_ctx.actor,
               execution_scope: person_ctx.scope,
               canonical_execution: true,
               history_binding: person_ctx.root,
               history_cursors: projection.cursors
             )

    on_exit(fn -> ServerManager.stop_server(ctx.agent, second_server_id) end)
    refute GenServer.whereis(second_server) == person_ctx.pid

    assert {:ok, second_lease} =
             ServerManager.begin_history_request(
               second_server_id,
               GenServer.whereis(second_server),
               person_ctx.actor
             )

    assert :ok =
             ServerManager.bind_history_request(second_server_id, second_lease.token, %{
               session: make_ref(),
               actor: person_ctx.actor,
               history: %{binding: person_ctx.root}
             })

    assert {:ok, %{request: second_request}} =
             Factory.ask_with_config(second_server, "Second root question", ctx.agent)

    assert :ok =
             ServerManager.bind_native_history_request(
               second_server_id,
               second_lease.token,
               second_request.id
             )

    assert_receive {:request_control_model_request, _, second_worker}, 5_000
    on_exit(fn -> send(second_worker, :release_request_control_model) end)

    child_input =
      incoming(person_ctx.info, "ambiguous-#{Ecto.UUID.generate()}", "Ambiguous input")

    assert {:ok, _} = HistoryIngress.capture(child_input)
    assert {:ok, binding} = Conversations.admit_incoming(child_input)

    event =
      Event.new(%{}, :agent,
        actor: person_ctx.actor,
        opts: [node_router: ControlledRouter, factory_module: ControlledFactory]
      )

    assert {:error, :ambiguous_request} =
             RequestControl.queue_incoming(
               event,
               child_input,
               %{kind: :canonical, transcript_id: person_ctx.transcript_id},
               binding,
               ctx.agent.id
             )

    refute_receive {:routed, _}
    refute_receive {:controlled, _, _}
  end

  test "an unexpected queue response cannot invoke Jido and reports history unavailable", ctx do
    {person_ctx, id} = canonical_active(ctx)
    Process.put(:request_control_test_owner, self())
    Process.put({:request_control_router_response, :queue_execution_input}, :unexpected)
    child = admitted_child(person_ctx, "Unexpected queue reply")

    event =
      Event.new(%{}, :agent,
        actor: person_ctx.actor,
        opts: [node_router: ControlledRouter, factory_module: ControlledFactory]
      )

    assert {:error, :history_unavailable} =
             RequestControl.control(event, id, "Unexpected queue reply", :inject_request, child)

    assert_receive {:routed, admitted}
    assert admitted.opts[:action] == :admit_execution
    assert_receive {:routed, queued}
    assert queued.opts[:action] == :queue_execution_input
    refute_receive {:controlled, _, _}
  end

  test "rejected canonical controls retain private receipts and report receipt failures precisely",
       ctx do
    {person_ctx, id} = canonical_active(ctx)
    Process.put(:request_control_test_owner, self())
    Process.put(:request_control_factory_result, {:error, {:rejected, :closed}})

    for {response, expected} <- [
          {:real, {:error, {:rejected, :closed}}},
          {{:error, :input_consumed}, {:error, :input_consumed}},
          {{:error, :ledger_down}, {:error, {:input_receipt_failed, :ledger_down}}},
          {:unavailable, {:error, {:input_receipt_failed, :unavailable}}}
        ] do
      child = admitted_child(person_ctx, "Rejected correction #{inspect(response)}")

      if response != :real do
        Process.put({:request_control_router_response, :reject_execution_input}, response)
      else
        Process.delete({:request_control_router_response, :reject_execution_input})
      end

      event =
        Event.new(%{}, :agent,
          actor: person_ctx.actor,
          opts: [node_router: ControlledRouter, factory_module: ControlledFactory]
        )

      assert ^expected =
               RequestControl.control(
                 event,
                 id,
                 "Rejected correction #{inspect(response)}",
                 :steer_request,
                 child
               )

      assert_receive {:routed, admitted}
      assert admitted.opts[:action] == :admit_execution
      assert_receive {:routed, queued}
      assert queued.opts[:action] == :queue_execution_input
      assert queued.request.binding == child
      assert_receive {:controlled, pid, control_opts}
      assert pid == person_ctx.pid
      assert control_opts[:expected_request_id] == id
      assert control_opts[:extra_refs].message_id == child.user_message_id
      assert_receive {:routed, rejected}
      assert rejected.opts[:action] == :reject_execution_input
      assert rejected.opts[:confidential] == true
      assert rejected.actor == person_ctx.actor
      assert rejected.request.root_user_message_id == person_ctx.root.user_message_id
      assert rejected.request.root_execution_id == person_ctx.root.execution_id
      assert rejected.request.user_message_id == child.user_message_id
      assert rejected.request.execution_id == control_opts[:extra_refs].execution_id
      assert rejected.request.reason == :closed_before_accept

      if response == :real do
        assert Repo.get_by!(ExecutionRecord, user_message_id: child.user_message_id).status ==
                 "unconsumed"
      end
    end
  end

  defp canonical_active(ctx) do
    person_ctx = canonical_person(ctx)

    assert {:ok, lease} =
             ServerManager.begin_history_request(ctx.scope, person_ctx.pid, person_ctx.actor)

    assert :ok =
             ServerManager.bind_history_request(ctx.scope, lease.token, %{
               session: make_ref(),
               actor: person_ctx.actor,
               history: %{binding: person_ctx.root}
             })

    assert {:ok, %{request: request}} =
             Factory.ask_with_config(person_ctx.server, "Root question", ctx.agent)

    assert :ok = ServerManager.bind_native_history_request(ctx.scope, lease.token, request.id)
    assert_receive {:request_control_model_request, _, worker}, 5_000
    on_exit(fn -> send(worker, :release_request_control_model) end)
    {person_ctx, request.id}
  end

  defp canonical_person(ctx) do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Request control",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: "https://history.example.test",
        token: "test-token"
      })
      |> Repo.insert!()

    {:ok, person} = People.create_person(%{full_name: "Request Owner"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "owner",
        channel_config_id: config.id
      })

    actor = %{person: %{id: person.id}}
    info = %{config: config, person: person, actor: actor}
    root_input = incoming(info, "root", "Root question")
    assert {:ok, _} = HistoryIngress.capture(root_input)
    assert {:ok, root} = Conversations.admit_incoming(root_input)

    {:ok, _} =
      Permissions.grant(
        ChannelHistoryResource.for("mattermost", config.id, "room"),
        %{person_id: person.id, access_rights: ["read"]}
      )

    assert {:ok, projection} = Conversations.admit_execution(root, actor, root_input.content)
    scope = "history:#{projection.transcript_id}:person:#{person.id}"
    assert :ok = ServerManager.stop_server(ctx.agent, ctx.scope)

    assert {:ok, server} =
             ServerManager.ensure_server(ctx.agent, ctx.scope, nil,
               actor: actor,
               execution_scope: scope,
               canonical_execution: true,
               history_binding: root,
               history_cursors: projection.cursors
             )

    assert GenServer.whereis(server) != ctx.pid
    # The caller's exact replacement incarnation is returned to the test below.
    %{
      info: info,
      root: root,
      person: person,
      actor: actor,
      scope: scope,
      transcript_id: projection.transcript_id,
      server: server,
      pid: GenServer.whereis(server)
    }
  end

  defp admitted_child(ctx, content) do
    input = incoming(ctx.info, "child-#{Ecto.UUID.generate()}", content)
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    binding
  end

  defp incoming(ctx, id, content) do
    Incoming.new(%{
      content: content,
      channel_id: "room",
      author_id: "owner",
      author_name: "Request Owner",
      message_id: id,
      provider: :mattermost,
      person: ctx.person,
      routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
    })
    |> CommunicationBridge.put_conversation_identity()
  end

  defp active_request(ctx) do
    assert {:ok, %{request: request}} = Factory.ask_with_config(ctx.server, "Question", ctx.agent)
    assert_receive {:request_control_model_request, _, worker}, 5_000
    on_exit(fn -> send(worker, :release_request_control_model) end)
    request.id
  end

  defp event(ctx, request, opts \\ []) do
    Event.new(request, :agent, actor: ctx.actor, opts: opts)
  end

  defp create_agent(credential_id, name) do
    Zaq.Agent.create_agent(%{
      name: "#{name} #{System.unique_integer([:positive])}",
      job: "Answer briefly.",
      model: "gpt-4.1-mini",
      credential_id: credential_id,
      strategy: "react",
      enabled_tool_keys: [],
      active: true,
      model_max_context_tokens: 20_000
    })
  end
end
