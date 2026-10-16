defmodule Zaq.Channels.MattermostSharedHistoryIntegrationTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Ecto.Adapters.SQL

  alias Zaq.Accounts.People
  alias Zaq.Agent.Executor
  alias Zaq.Agent.HistorySync
  alias Zaq.Agent.RequestControl
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.MattermostAdmin
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Api
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ChannelHistoryMembership
  alias Zaq.Engine.Conversations

  alias Zaq.Engine.Conversations.{
    ExecutionRecord,
    Message,
    TokenUsageAggregator,
    Transcript,
    TranscriptMessage
  }

  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Permissions.ChannelHistoryResource

  alias Zaq.TestSupport.{
    MattermostHistoryFixture,
    MultiAgentOpenAIStub,
    OpenAIStub,
    ToolCallingLLMStub
  }

  @keys [
    :channels,
    :chat_bridge_pipeline_module,
    :chat_bridge_node_router_module,
    :chat_bridge_accounts_module,
    :chat_bridge_permissions_module,
    :chat_bridge_supervisor_module,
    :chat_bridge_chat_module,
    :pipeline_hooks_module
  ]

  setup tags do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    owner = self()
    observe_history_commit(owner)
    previous = Map.new(@keys, &{&1, Application.fetch_env(:zaq, &1)})
    Enum.each(@keys, &Application.delete_env(:zaq, &1))

    Application.put_env(:zaq, :channels, %{
      email: %{bridge: EmailBridge},
      mattermost: %{
        bridge: JidoChatBridge,
        adapter: Jido.Chat.Mattermost.Adapter,
        ingress_mode: :webhook
      }
    })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:zaq, key, value)
        {key, :error} -> Application.delete_env(:zaq, key)
      end)
    end)

    llm_handler = history_llm_handler(tags, owner)
    delivery_counter = :atomics.new(1, [])

    handler = fn conn, body ->
      if llm_handler && conn.request_path == "/v1/responses" do
        request = Jason.decode!(body)
        send(owner, {:history_llm, request})

        if tags[:membership_removal] || tags[:boundary_revocation] || tags[:boundary_persistence] ||
             history_barrier?(tags, request, body) do
          barrier_timeout = if tags[:queue_overflow], do: 60_000, else: 10_000
          send(owner, {:history_llm_barrier, self()})

          receive do
            :release_history_llm -> :ok
          after
            barrier_timeout -> flunk("external LLM barrier was not released")
          end
        end

        llm_handler.(conn, body)
      else
        delivery_http(tags, conn, body, owner, delivery_counter)
      end
    end

    {child, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(child)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "History Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "Answer briefly.",
        model: "gpt-4.1-mini",
        model_max_context_tokens: 20_000,
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: if(tags[:authorized_execution], do: ["arithmetic.add"], else: []),
        conversation_enabled: true,
        active: true,
        advanced_options:
          if(tags[:queue_overflow],
            do: %{"stream" => false, "receive_timeout" => 120_000},
            else: %{"stream" => false}
          )
      })

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Shared Mattermost",
        provider: "mattermost",
        kind: "retrieval",
        url: String.trim_trailing(endpoint, "/v1"),
        token: "test-token",
        enabled: true,
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot"}}
      })
      |> Repo.insert!()

    {:ok, person} = People.create_person(%{full_name: "Alice"})

    unless tags[:authorized_execution] do
      assert {:ok, _} =
               Zaq.Permissions.grant(
                 ChannelHistoryResource.for(
                   "mattermost",
                   config.id,
                   "shared-room"
                 ),
                 %{person_id: person.id, access_rights: ["read"]}
               )
    end

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "alice",
        channel_config_id: config.id
      })

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(
        %{channel_config_id: config.id},
        %{routing_mode: :agent, configured_agent_id: agent.id}
      )

    on_exit(fn ->
      ServerManager.stop_server(agent)
      Zaq.Channels.Supervisor.stop_bridge_runtime(config, "mattermost_#{config.id}")
    end)

    %{config: config, person: person, agent: agent}
  end

  for {steering_mode, retained_root?} <- [
        {:explicit_control, true},
        {:provider_mention, true},
        {:attachment_control, true},
        {:explicit_control, false}
      ] do
    @steering_mode steering_mode
    @tag steering_mode: steering_mode
    @retained_root retained_root?
    @tag :authorized_execution
    @tag :input_consumption
    test "authorized thread history and #{@steering_mode} with retained root #{@retained_root} reach the real tool-calling agent without private data",
         ctx do
      {:ok, bob} = People.create_person(%{full_name: "Bob"})

      {:ok, _} =
        People.add_channel(%{
          person_id: bob.id,
          platform: "mattermost",
          channel_identifier: "bob",
          channel_config_id: ctx.config.id
        })

      assert {{:ok, _}, _} =
               MattermostHistoryFixture.post(ctx.config, nil, false, %{
                 "id" => if(@retained_root, do: "root-human", else: "passive-parent"),
                 "user_id" => "bob",
                 "message" =>
                   if(@retained_root,
                     do: "Authorized project root",
                     else: "Authorized parent context"
                   )
               })

      parent =
        Repo.one!(
          from t in Transcript,
            where: t.external_channel_id == "shared-room" and is_nil(t.parent_id)
        )

      # Explicit BO control is tested with independently managed manual access.
      # Provider ingress must establish legitimate access itself; a manual grant
      # here previously hid the production mention authorization regression.
      if @steering_mode == :explicit_control do
        assert {:ok, _} =
                 Zaq.Permissions.grant(
                   {parent.permission_resource_type, parent.permission_resource_id},
                   %{person_id: ctx.person.id, access_rights: ["read"]}
                 )
      end

      root =
        Repo.get_by!(Message,
          external_message_id: if(@retained_root, do: "root-human", else: "passive-parent")
        )

      %ExecutionRecord{}
      |> ExecutionRecord.changeset(%{
        person_id: bob.id,
        user_message_id: root.id,
        finalization_token_hash: :crypto.hash(:sha256, "private-execution") |> Base.encode64(),
        trace_entries: [%{"content" => "FORBIDDEN_PRIVATE_TRACE"}],
        tool_results: [%{"content" => "FORBIDDEN_PRIVATE_TOOL"}]
      })
      |> Repo.insert!()

      assert {{:ok, _}, _} =
               MattermostHistoryFixture.post(ctx.config, "human", false, %{
                 "id" => "passive-thread",
                 "user_id" => "bob",
                 "message" => "Authorized thread evidence"
               })

      assert {{:ok, _}, _} =
               MattermostHistoryFixture.post(ctx.config, nil, false, %{
                 "id" => "forbidden-room",
                 "user_id" => "bob",
                 "channel_id" => "private-room",
                 "message" => "FORBIDDEN_OTHER_ROOM"
               })

      assert {{:ok, _}, post} = MattermostHistoryFixture.post(ctx.config, "human", true)
      assert_receive {:history_llm, request}, 5_000
      assert_receive {:history_llm_barrier, worker}, 5_000
      on_exit(fn -> send(worker, :release_history_llm) end)

      scope =
        "history:#{Repo.get_by!(Transcript, external_thread_id: "root-human").id}:person:#{ctx.person.id}"

      actor = %{person: %{id: ctx.person.id}}

      assert {:ok, {request_id, state}} =
               RequestControl.find_native_request(scope, actor)

      assert state.actor.person.id == ctx.person.id
      assert state.execution_scope == scope
      assert state.agent.id == ctx.agent.id
      assert is_pid(state.runtime_pid)
      assert Process.alive?(state.runtime_pid)
      assert_rejected_control_receipt(ctx, state, actor)
      assert_failed_receipt_persistence(ctx, request_id, actor)

      steering =
        Incoming.new(%{
          content: "@zaq Retain the arithmetic tool result",
          attachments:
            if(@steering_mode == :attachment_control,
              do: [
                %Record{
                  id: "correction-record",
                  kind: :file,
                  name: "correction.pdf",
                  mime_type: "application/pdf",
                  materialization_handle: "correction-signed-handle"
                }
              ],
              else: []
            ),
          channel_id: "shared-room",
          author_id: "alice",
          author_name: "Alice",
          message_id: "steering-input",
          thread_id: "root-human",
          provider: :mattermost,
          person: ctx.person,
          routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
        })
        |> CommunicationBridge.put_conversation_identity()

      binding =
        case @steering_mode do
          :attachment_control ->
            assert {:ok, _} = HistoryIngress.capture(steering)
            assert {:ok, binding} = Conversations.admit_incoming(steering)

            assert {:ok, projection} =
                     Conversations.admit_execution(binding, actor, steering.content)

            control = Zaq.Event.new(steering, :agent, actor: actor)

            assert {:queued, _} =
                     RequestControl.queue_incoming(
                       control,
                       steering,
                       projection,
                       binding,
                       ctx.agent.id
                     )

            binding

          :explicit_control ->
            assert {:ok, _} = HistoryIngress.capture(steering)
            assert {:ok, binding} = Conversations.admit_incoming(steering)

            control =
              Zaq.Event.new(
                %{
                  request_id: request_id,
                  content: steering.content,
                  conversation_binding: binding
                },
                :agent,
                actor: actor
              )

            assert %{response: {:ok, _}} =
                     Zaq.Agent.Api.handle_event(control, :steer_request, nil)

            binding

          :provider_mention ->
            assert {{:ok, _}, _} =
                     MattermostHistoryFixture.post(ctx.config, "human", true, %{
                       "id" => "steering-input",
                       "message" => steering.content
                     })

            assert_receive :history_input_queued, 5_000
            %{user_message_id: Repo.get_by!(Message, external_message_id: "steering-input").id}
        end

      assert Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id).status ==
               "queued"

      assert {{:ok, _}, _} =
               MattermostHistoryFixture.post(ctx.config, "human", false, %{
                 "id" => "passive-turn-delta",
                 "user_id" => "bob",
                 "message" => "Passive refresh A"
               })

      send(worker, :release_history_llm)
      input = Jason.encode!(request["input"])

      if @retained_root do
        assert input =~ "Authorized project root"
        assert length(Regex.scan(~r/Authorized project root/, input)) == 1
      else
        assert input =~ "Authorized parent context"
        refute input =~ "Authorized project root"
        assert Repo.get_by(Message, external_message_id: "root-human") == nil
      end

      assert input =~ "Authorized thread evidence"
      assert input =~ "Author: \\\"Bob\\\" [person:#{bob.id}]"
      assert length(Regex.scan(~r/history question/, input)) == 1
      refute input =~ "FORBIDDEN_"

      assert_receive {:llm_tool_call, "add", %{"value" => 2, "amount" => 3}}, 5_000
      assert_receive {:llm_tool_result, "add", result}, 5_000
      assert result == %{"ok" => true, "result" => %{"result" => 5.0}}
      assert_receive {:history_llm, continuation}, 5_000
      refute Jason.encode!(continuation["input"]) =~ "FORBIDDEN_"
      assert Jason.encode!(continuation["input"]) =~ steering.content

      if @steering_mode == :attachment_control do
        payload = Jason.encode!(continuation["input"])
        assert length(Regex.scan(~r/correction\.pdf/, payload)) == 1
        refute payload =~ "correction-signed-handle"
        assert Repo.get!(Message, binding.user_message_id).content == steering.content
      end

      assert length(Regex.scan(~r/Passive refresh A/, Jason.encode!(continuation["input"]))) == 1

      assert length(
               Regex.scan(
                 ~r/Retain the arithmetic tool result/,
                 Jason.encode!(continuation["input"])
               )
             ) == 1

      assert_receive {:history_post, %{"channel_id" => "shared-room", "root_id" => "root-human"}},
                     5_000

      child = Repo.get_by!(Transcript, external_thread_id: "root-human")
      answer = await_answer(child.id)
      outgoing = await_delivery_event()
      assert answer.content == "History answer"
      assert outgoing.metadata[:assistant_message_id] == answer.id
      assert outgoing.routing_context.channel_config_id == ctx.config.id
      assert Conversations.get_conversation!(answer.conversation_id).person_id == ctx.person.id
      input_message = Repo.get_by!(Message, external_message_id: post["id"])
      execution = Repo.get_by!(ExecutionRecord, user_message_id: input_message.id)
      assert execution.person_id == ctx.person.id
      assert execution.status == "completed"
      assert execution.public_answer_message_id == answer.id
      assert execution.usage["prompt_tokens"] == 10
      assert execution.usage["completion_tokens"] == 2
      assert execution.usage["total_tokens"] == 12
      assert length(execution.tool_results) == 1
      assert answer.trace == []
      assert answer.prompt_tokens == nil
      assert answer.completion_tokens == nil
      date = answer.inserted_at |> DateTime.to_date() |> Date.to_iso8601()

      job = %Oban.Job{
        args: %{
          "conversation_id" => answer.conversation_id,
          "model" => answer.model,
          "date" => date
        }
      }

      assert :ok = TokenUsageAggregator.perform(job)
      metadata = Conversations.get_conversation!(answer.conversation_id).metadata

      assert metadata["token_usage"][date][answer.model] ==
               %{"prompt_tokens" => 10, "completion_tokens" => 2, "total_tokens" => 12}

      assert :ok = TokenUsageAggregator.perform(job)
      assert Conversations.get_conversation!(answer.conversation_id).metadata == metadata
      receipt = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)
      assert receipt.status == "consumed"
      assert receipt.root_execution_id == execution.id
      assert receipt.public_answer_message_id == nil

      ids = Repo.all(from m in Message, select: m.id, order_by: m.id)
      count = Repo.aggregate(TranscriptMessage, :count)
      assert {{:ok, _}, ^post} = MattermostHistoryFixture.post(ctx.config, "human", true)
      assert Repo.all(from m in Message, select: m.id, order_by: m.id) == ids
      assert Repo.aggregate(TranscriptMessage, :count) == count
      refute_receive {:history_llm, _}, 200
      refute_received {:history_post, _}
      refute_received {:llm_stub_error, _}
      refute_received {:unexpected_history_http, _}
    end
  end

  for {name, root_author, mention?, answers?} <- MattermostHistoryFixture.scenarios() do
    @root_author root_author
    @mention mention?
    @answers answers?
    test name, ctx do
      {result, post} = MattermostHistoryFixture.post(ctx.config, @root_author, @mention)
      assert {:ok, %{auth_status: :ok}} = result

      # Listener processing is synchronous; this assertion checks real ingress,
      # including validation before canonical storage, rather than injecting Facts.
      input = Repo.get_by(Message, external_message_id: post["id"])
      assert input, "the actual adapter ingress must persist the message"
      assert input.content == post["message"]
      assert input.author_id == "alice"
      assert input.source_provider == "mattermost"
      assert input.source_account_key == Jason.encode!(["mattermost", ctx.config.id, nil])
      [placement] = Repo.all(from p in TranscriptMessage, where: p.message_id == ^input.id)
      transcript = Repo.get!(Transcript, placement.transcript_id)
      assert transcript.strategy == "shared"
      assert transcript.channel_config_id == ctx.config.id
      assert transcript.external_channel_id == "shared-room"

      assert transcript.external_thread_id ==
               if(@root_author, do: "root-#{@root_author}", else: nil)

      assert Zaq.Permissions.can?(
               ctx.person,
               "read",
               {transcript.permission_resource_type, transcript.permission_resource_id}
             )

      if @root_author do
        parent = Repo.get!(Transcript, transcript.parent_id)
        assert parent.external_thread_id == nil
        assert parent.channel_config_id == ctx.config.id
        assert parent.permission_resource_id == transcript.permission_resource_id
      else
        assert transcript.parent_id == nil
      end

      if @answers do
        assert_receive {:history_llm, _request}, 5_000
        assert_receive {:history_post, sent}, 5_000
        assert sent["channel_id"] == "shared-room"
        assert sent["root_id"] == if(@root_author, do: "root-#{@root_author}", else: nil)
        assert_receive {:history_update, %{"message" => "History answer"}}, 5_000
        answer = await_answer(transcript.id)
        assert answer.content == "History answer"
        outgoing = await_delivery_event()
        assert outgoing.metadata[:assistant_message_id] == answer.id
        assert outgoing.metadata[:conversation_id] == answer.conversation_id
        conversation = Conversations.get_conversation!(answer.conversation_id)
        assert conversation.person_id == ctx.person.id
        assert Repo.aggregate(Message, :count) == 2
        assert Repo.aggregate(TranscriptMessage, :count) == 2
        refute_received {:history_llm, _}
        refute_received {:history_post, _}
      else
        refute_received {:history_llm, _}
        refute_received {:history_post, _}
        assert Repo.aggregate(Message, :count) == 1
      end

      # The same transport event may be redelivered after successful processing.
      # It must retain both canonical UUIDs and must not activate a second answer.
      ids = Repo.all(from m in Message, select: m.id, order_by: m.id)
      placement_count = Repo.aggregate(TranscriptMessage, :count)
      assert {{:ok, _}, ^post} = MattermostHistoryFixture.post(ctx.config, @root_author, @mention)
      assert Repo.all(from m in Message, select: m.id, order_by: m.id) == ids
      assert Repo.aggregate(TranscriptMessage, :count) == placement_count
      refute_receive {:history_llm, _}, 200
      refute_received {:history_post, _}
      refute_received {:unexpected_history_http, _}

      if @root_author do
        admin = super_admin_fixture()

        event =
          Zaq.Event.new(%{op: :detail, id: transcript.id}, :engine,
            actor: %{user_id: admin.id},
            opts: [action: :channel_history_admin, confidential: true]
          )

        assert %{response: {:ok, %{root_message: root}}} =
                 Api.handle_event(event, :channel_history_admin, %{})

        assert root.content == "Root message"
        assert root.author_id == @root_author
        assert Repo.all(from m in Message, select: m.id, order_by: m.id) == ids
      end
    end
  end

  test "same provider identifiers on another connector get an independent parent and grant scope",
       ctx do
    other = ctx.config |> Ecto.reset_fields([:id, :inserted_at, :updated_at]) |> Repo.insert!()

    {:ok, _} =
      People.add_channel(%{
        person_id: ctx.person.id,
        platform: "mattermost",
        channel_identifier: "alice",
        channel_config_id: other.id
      })

    on_exit(fn ->
      Zaq.Channels.Supervisor.stop_bridge_runtime(other, "mattermost_#{other.id}")
    end)

    for config <- [ctx.config, other] do
      assert {{:ok, _}, _} = MattermostHistoryFixture.post(config, "human", false)
    end

    children =
      Repo.all(
        from t in Transcript, where: not is_nil(t.parent_id), order_by: t.channel_config_id
      )

    assert length(children) == 2
    assert Enum.map(children, & &1.channel_config_id) == Enum.sort([ctx.config.id, other.id])
    assert MapSet.size(MapSet.new(Enum.map(children, & &1.permission_resource_id))) == 2

    for child <- children do
      parent = Repo.get!(Transcript, child.parent_id)
      assert parent.channel_config_id == child.channel_config_id
      assert parent.permission_resource_id == child.permission_resource_id
      assert parent.next_position == 0
      assert child.next_position == 1
    end

    assert Repo.aggregate(Message, :count) == 2
    assert Repo.aggregate(TranscriptMessage, :count) == 2
    refute_receive {:history_llm, _}, 200
    refute_received {:history_post, _}
  end

  for server <- [:same, :different] do
    @server server
    test "second connector discovers the same Person on #{@server} server and delivers a reply",
         ctx do
      {:ok, _} = People.update_person(ctx.person, %{email: "alice@example.com"})
      owner = self()

      url =
        if @server == :different do
          {child, endpoint} =
            OpenAIStub.server(&MattermostHistoryFixture.http(&1, &2, owner), owner)

          start_supervised!(Supervisor.child_spec(child, id: :second_mattermost))
          String.trim_trailing(endpoint, "/v1")
        else
          ctx.config.url
        end

      other =
        ctx.config
        |> Ecto.reset_fields([:id, :inserted_at, :updated_at])
        |> Map.put(:url, url)
        |> Repo.insert!()

      on_exit(fn ->
        Zaq.Channels.Supervisor.stop_bridge_runtime(other, "mattermost_#{other.id}")
      end)

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(
          %{channel_config_id: other.id},
          %{routing_mode: :agent, configured_agent_id: ctx.agent.id}
        )

      assert {:error, :not_found} = People.match_by_channel("mattermost", "alice", other.id)
      people_count = Repo.aggregate(Zaq.Accounts.Person, :count)

      assert {:ok, _} =
               Zaq.Permissions.grant(
                 ChannelHistoryResource.for(
                   "mattermost",
                   other.id,
                   "shared-room"
                 ),
                 %{person_id: ctx.person.id, access_rights: ["read"]}
               )

      assert {{:ok, _}, post} = MattermostHistoryFixture.post(other, nil, true)
      assert {:ok, resolved} = People.match_by_channel("mattermost", "alice", other.id)
      assert resolved.id == ctx.person.id
      assert {:ok, original} = People.match_by_channel("mattermost", "alice", ctx.config.id)
      assert original.id == resolved.id
      assert Repo.aggregate(Zaq.Accounts.Person, :count) == people_count
      assert_receive {:history_llm, _}, 5_000
      assert_receive {:history_post, %{"channel_id" => "shared-room"}}, 5_000
      assert_receive {:history_update, %{"message" => "History answer"}}, 5_000
      transcript = Repo.get_by!(Transcript, channel_config_id: other.id)
      answer = await_answer(transcript.id)
      outgoing = await_delivery_event()
      assert outgoing.routing_context.channel_config_id == other.id
      assert outgoing.metadata[:assistant_message_id] == answer.id
      assert Conversations.get_conversation!(answer.conversation_id).person_id == ctx.person.id
      assert Repo.aggregate(TranscriptMessage, :count) == 2

      assert {{:ok, _}, ^post} = MattermostHistoryFixture.post(other, nil, true)
      assert Repo.aggregate(TranscriptMessage, :count) == 2
      assert Repo.aggregate(Zaq.Accounts.Person, :count) == people_count
      refute_receive {:history_llm, _}, 200
      refute_received {:unexpected_history_http, _}
    end
  end

  test "provider root lookup rejects a post from a different room", ctx do
    assert {:error, :unavailable} =
             MattermostAdmin.fetch_room_message(ctx.config, "another-room", "root-human")
  end

  @tag :queue_overflow
  @tag :input_consumption
  @tag timeout: 120_000
  test "real Jido overflow preserves consumption and rejection without extra answers", ctx do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "overflow-root",
               "message" => "@zaq history question"
             })

    assert_receive {:history_llm, _}, 5_000
    assert_receive {:history_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_history_llm) end)
    transcript = Repo.get_by!(Transcript, external_thread_id: "root-human")
    actor = %{person: %{id: ctx.person.id}}
    scope = "history:#{transcript.id}:person:#{ctx.person.id}"

    assert {:ok, {request_id, _state}} =
             RequestControl.find_native_request(scope, actor)

    receipts =
      for index <- 1..65 do
        input =
          Incoming.new(%{
            content: "@zaq correction #{index}",
            channel_id: "shared-room",
            author_id: "alice",
            message_id: "overflow-#{index}",
            thread_id: "root-human",
            provider: :mattermost,
            person: ctx.person,
            routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
          })
          |> CommunicationBridge.put_conversation_identity()

        assert {:ok, _} = HistoryIngress.capture(input)
        assert {:ok, binding} = Conversations.admit_incoming(input)

        event =
          Zaq.Event.new(
            %{request_id: request_id, content: input.content, conversation_binding: binding},
            :agent,
            actor: actor
          )

        result = Zaq.Agent.Api.handle_event(event, :steer_request, nil)
        record = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)

        if index <= 64 do
          assert %{response: {:ok, _}} = result
          assert record.status == "queued"
        else
          assert %{response: {:error, {:rejected, :queue_full}}} = result
          assert record.status == "unconsumed"
          assert record.outcome["reason"] == "runtime_rejected"
        end

        record.id
      end

    send(worker, :release_history_llm)
    answer = await_answer(transcript.id)
    assert answer.content == "Sealed root answer"
    root_input = Repo.get_by!(Message, external_message_id: "overflow-root")
    root = Repo.get_by!(ExecutionRecord, user_message_id: root_input.id)
    assert root.status == "completed"
    assert root.public_answer_message_id == answer.id

    for {id, index} <- Enum.with_index(receipts, 1) do
      receipt = Repo.get!(ExecutionRecord, id)
      assert receipt.status == if(index <= 64, do: "consumed", else: "unconsumed")
      assert receipt.root_execution_id == root.id
      assert receipt.public_answer_message_id == nil
    end

    assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 1
    assert Repo.aggregate(from(m in Message, where: m.role == "user"), :count) == 66
  end

  @tag :root_failure
  @tag :input_consumption
  test "real LLM failure seals accepted corrections without claiming consumption or an answer",
       ctx do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "failed-root",
               "message" => "@zaq history question"
             })

    assert_receive {:history_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_history_llm) end)
    transcript = Repo.get_by!(Transcript, external_thread_id: "root-human")
    actor = %{person: %{id: ctx.person.id}}
    scope = "history:#{transcript.id}:person:#{ctx.person.id}"
    assert {:ok, {request_id, _}} = RequestControl.find_native_request(scope, actor)

    receipts =
      for index <- 1..2 do
        input =
          Incoming.new(%{
            content: "@zaq failed-run correction #{index}",
            channel_id: "shared-room",
            author_id: "alice",
            message_id: "failed-correction-#{index}",
            thread_id: "root-human",
            provider: :mattermost,
            person: ctx.person,
            routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
          })
          |> CommunicationBridge.put_conversation_identity()

        assert {:ok, _} = HistoryIngress.capture(input)
        assert {:ok, binding} = Conversations.admit_incoming(input)

        event =
          Zaq.Event.new(
            %{request_id: request_id, content: input.content, conversation_binding: binding},
            :agent,
            actor: actor
          )

        assert %{response: {:ok, _}} = Zaq.Agent.Api.handle_event(event, :steer_request, nil)
        receipt = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)
        assert receipt.status == "queued"
        receipt.id
      end

    send(worker, :release_history_llm)
    assert_receive {:history_execution_failed, writer}, 5_000
    monitor = Process.monitor(writer)
    assert_receive {:DOWN, ^monitor, :process, ^writer, reason}, 5_000
    assert reason in [:normal, :noproc]
    root_input = Repo.get_by!(Message, external_message_id: "failed-root")
    root = Repo.get_by!(ExecutionRecord, user_message_id: root_input.id)
    assert root.status == "failed"
    assert root.public_answer_message_id == nil

    for id <- receipts do
      receipt = Repo.get!(ExecutionRecord, id)
      assert receipt.status == "unconsumed"
      assert receipt.public_answer_message_id == nil
      assert receipt.root_execution_id == root.id
    end

    assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 0
    assert Repo.aggregate(from(m in Message, where: m.role == "user"), :count) == 3
  end

  @tag :membership_removal
  @tag :authorized_execution
  test "provider removal with manual access preserves accepted execution and the same warm runtime",
       ctx do
    owner = self()
    handler = {__MODULE__, :removal_http, self()}

    :telemetry.attach(
      handler,
      [:finch, :queue, :start],
      fn _, _, metadata, _ ->
        if metadata.name == ReqLLM.Finch, do: send(owner, {:removal_http, self()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", false, %{
               "id" => "removal-seed",
               "message" => "Membership seed"
             })

    event = %{
      provider: "mattermost",
      channel_config_id: ctx.config.id,
      channel_id: "shared-room",
      identity_platform: "mattermost",
      member_id: "alice",
      operation: :add,
      revision: 1
    }

    assert {:ok, %{status: :applied}} = ChannelHistoryMembership.apply_event(event)
    resource = ChannelHistoryResource.for("mattermost", ctx.config.id, "shared-room")

    assert {:ok, _} =
             Zaq.Permissions.grant(
               resource,
               %{person_id: ctx.person.id, access_rights: ["read"]}
             )

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "removal-root",
               "message" => "@zaq Finish only while a member"
             })

    assert_receive {:history_llm, _}, 5_000
    assert_receive {:history_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_history_llm) end)
    input = Repo.get_by!(Message, external_message_id: "removal-root")
    placement = Repo.get_by!(TranscriptMessage, message_id: input.id)
    transcript = Repo.get!(Transcript, placement.transcript_id)
    membership_source = transcript.parent_id || transcript.id
    scope = "history:#{placement.transcript_id}:person:#{ctx.person.id}"
    server_id = "#{ctx.agent.name}:#{scope}"
    ledger = :sys.get_state(ServerManager).history[server_id]
    runtime_monitor = Process.monitor(ledger.pid)
    owner_monitor = Process.monitor(ledger.lease.owner)

    {:ok, {_request_id, _}} =
      RequestControl.find_native_request(
        scope,
        %{person: %{id: ctx.person.id}},
        ledger.pid
      )

    removal = %{event | operation: :remove, revision: 2}
    assert_receive {:removal_http, http}, 5_000
    http_monitor = Process.monitor(http)
    {:ok, %{raw_state: %{__strategy__: native}}} = Jido.AgentServer.status(ledger.pid)

    {:ok, %{raw_state: %{__strategy__: native_worker}}} =
      Jido.AgentServer.status(native.react_worker_pid)

    runner_monitor = Process.monitor(native_worker.runtime_task)

    assert {:ok, %{status: :applied}} = ChannelHistoryMembership.apply_event(removal)
    refute_receive {:DOWN, ^runtime_monitor, :process, _, _}, 1_600
    assert Process.alive?(native_worker.runtime_task)
    assert Process.alive?(http)
    send(worker, :release_history_llm)
    assert await_delivery_event().body == "History answer"
    assert_receive {:DOWN, ^runner_monitor, :process, _, _}, 5_000
    assert_receive {:DOWN, ^http_monitor, :process, ^http, _}, 5_000
    assert_receive {:DOWN, ^owner_monitor, :process, _, _}, 5_000
    assert :ets.whereis(:zaq_agent_request_observations) == :undefined

    assert {:error, :not_found} =
             RequestControl.find_native_request(scope, %{person: %{id: ctx.person.id}})

    assert Repo.get_by!(ExecutionRecord, user_message_id: input.id).status == "completed"
    assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 1

    assert Enum.map(Zaq.Permissions.list_direct(resource), & &1.source_key) == ["manual"]
    assert :sys.get_state(ServerManager).history[server_id].pid == ledger.pid
    assert Repo.get!(Transcript, membership_source).membership_state["removal_generation"] == nil

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "removal-restart",
               "message" => "@zaq Restart through surviving manual access"
             })

    assert_receive {:history_llm, _}, 5_000
    assert_receive {:history_llm_barrier, next_worker}, 5_000
    on_exit(fn -> send(next_worker, :release_history_llm) end)
    next = :sys.get_state(ServerManager).history[server_id]
    assert next.pid == ledger.pid

    assert [] =
             Repo.all(
               from j in Oban.Job, where: j.worker == "Zaq.Engine.HistoryRuntimeRemovalWorker"
             )

    assert Process.alive?(next.pid)
    assert {:ok, %{status: :stale}} = ChannelHistoryMembership.apply_event(removal)
    assert Process.alive?(next.pid)
    delivery_monitor = Process.monitor(next.lease.owner)
    send(next_worker, :release_history_llm)
    assert await_delivery_event().body == "History answer"
    assert_receive {:DOWN, ^delivery_monitor, :process, _, _}, 5_000
  end

  @tag :membership_removal
  @tag :authorized_execution
  @tag :accepted_busy_waiter
  test "a standalone accepted Executor waiting on a busy lease finishes after root closure and access loss",
       ctx do
    resource = ChannelHistoryResource.for("mattermost", ctx.config.id, "shared-room")

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "busy-wait-root",
               "message" => "@zaq Finish only while a member"
             })

    assert_receive {:history_llm, _initial}, 5_000
    assert_receive {:history_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_history_llm) end)

    transcript =
      Repo.get_by!(Transcript, external_thread_id: "root-human", channel_config_id: ctx.config.id)

    server_id = "#{ctx.agent.name}:history:#{transcript.id}:person:#{ctx.person.id}"
    assert %{pid: pid} = :sys.get_state(ServerManager).history[server_id]
    assert Process.alive?(pid)
    manager = Process.whereis(ServerManager)
    :erlang.trace(manager, true, [:receive, {:tracer, self()}])
    on_exit(fn -> if Process.alive?(manager), do: :erlang.trace(manager, false, [:receive]) end)

    input =
      Incoming.new(%{
        provider: :mattermost,
        person: ctx.person,
        author_id: "alice",
        content: "@zaq Accepted waiting input",
        channel_id: "shared-room",
        message_id: "busy-wait-child",
        thread_id: "root-human",
        routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
      })
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    actor = %{person: %{id: ctx.person.id}}
    parent = self()

    waiter =
      Task.async(fn ->
        HistorySync.with_session(fn session ->
          opts = [
            history_session: session,
            conversation_binding: binding,
            agent_id: ctx.agent.id,
            person_id: ctx.person.id,
            event: Zaq.Event.new(input, :agent, actor: actor)
          ]

          assert {:ok, _} =
                   HistorySync.execution_admission(opts, binding, actor, input.content)

          send(parent, {:busy_input_admitted, self()})
          outgoing = Executor.run(input, opts)
          refute outgoing.metadata.error

          assert {:ok, persisted} =
                   Conversations.finalize_incoming(
                     binding.user_message_id,
                     binding.finalization_token,
                     %{answer: outgoing.body, error: false},
                     actor: actor,
                     execution_id: binding.execution_id
                   )

          assert :ok = HistorySync.complete(session, persisted, outgoing)
          outgoing
        end)
      end)

    waiter_pid = waiter.pid
    assert_receive {:busy_input_admitted, ^waiter_pid}, 5_000

    assert_receive {:trace, ^manager, :receive,
                    {:"$gen_call", {^waiter_pid, _}, {:begin_history_request, ^server_id, _, _}}},
                   5_000

    ledger = :sys.get_state(manager).history[server_id]
    assert length(ledger.waiters) == 1
    assert map_size(ledger.pins) == 2
    permission = actual_provider_permission(resource, ctx.person)
    assert :ok = Zaq.Permissions.revoke(resource, permission)
    monitor = Process.monitor(ledger.pid)
    send(worker, :release_history_llm)
    assert await_delivery_event().body == "History answer"
    assert_receive {:history_llm, next_turn}, 5_000
    assert MultiAgentOpenAIStub.latest_user_message(next_turn) =~ "Accepted waiting input"
    assert_receive {:history_llm_barrier, next_worker}, 5_000
    on_exit(fn -> send(next_worker, :release_history_llm) end)
    send(next_worker, :release_history_llm)
    assert %Outgoing{body: "History answer"} = Task.await(waiter, 5_000)
    assert Repo.get!(ExecutionRecord, binding.execution_id).status == "completed"
    root = Repo.get_by!(Message, external_message_id: "busy-wait-root")
    assert Repo.get_by!(ExecutionRecord, user_message_id: root.id).status == "completed"
    assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 2
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
  end

  @tag :boundary_persistence
  @tag :authorized_execution
  test "next admission stays fenced after native terminalization through real outcome persistence",
       ctx do
    assert {:ok, _} =
             Zaq.Permissions.grant(
               ChannelHistoryResource.for("mattermost", ctx.config.id, "shared-room"),
               %{person_id: ctx.person.id, access_rights: ["read"]}
             )

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "boundary-persistence-root",
               "message" => "@zaq Persist before next admission"
             })

    assert_receive {:history_llm, _}, 5_000
    assert_receive {:history_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_history_llm) end)
    root = Repo.get_by!(Message, external_message_id: "boundary-persistence-root")
    placement = Repo.get_by!(TranscriptMessage, message_id: root.id)
    scope = "history:#{placement.transcript_id}:person:#{ctx.person.id}"
    server_id = "#{ctx.agent.name}:#{scope}"
    ledger = :sys.get_state(ServerManager).history[server_id]
    delivery_monitor = Process.monitor(ledger.lease.owner)

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", false, %{
               "id" => "boundary-persistence-background",
               "message" => "During persistence background"
             })

    owner = self()
    handler = {__MODULE__, :boundary_persistence, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:zaq, :repo, :query],
               fn _, _, metadata, _ ->
                 if self() == ledger.lease.owner and metadata[:source] == "execution_records" and
                      "completed" in (metadata[:params] || []) do
                   send(owner, {:boundary_persist_writer, self()})

                   receive do
                     :release_boundary_persistence -> :ok
                   after
                     10_000 -> flunk("outcome persistence barrier was not released")
                   end
                 end
               end,
               nil
             )

    on_exit(fn ->
      send(ledger.lease.owner, :release_boundary_persistence)
      :telemetry.detach(handler)
    end)

    send(worker, :release_history_llm)
    assert_receive {:boundary_persist_writer, writer}, 5_000
    assert writer == ledger.lease.owner
    assert {:ok, %{raw_state: %{__strategy__: strategy}}} = Jido.AgentServer.status(ledger.pid)
    assert strategy.status == :completed
    assert strategy.active_request_id == nil

    refute match?(
             {:ok, _},
             RequestControl.find_native_request(
               scope,
               %{person: %{id: ctx.person.id}},
               ledger.pid
             )
           )

    manager = Process.whereis(ServerManager)
    :erlang.trace(manager, true, [:receive, {:tracer, self()}])
    on_exit(fn -> :erlang.trace(manager, false, [:receive]) end)

    waiter =
      Task.async(fn ->
        assert {:ok, lease} =
                 ServerManager.begin_history_request(server_id, ledger.pid, %{
                   person: %{id: ctx.person.id}
                 })

        assert {:ok, %{raw_state: %{__strategy__: applied}}} = Jido.AgentServer.status(lease.pid)

        assert :ok =
                 ServerManager.complete_history_request(
                   server_id,
                   lease.token,
                   applied.context,
                   lease.cursors
                 )

        {lease, applied.context}
      end)

    assert_receive {:trace, ^manager, :receive,
                    {:"$gen_call", {waiter_pid, _}, {:begin_history_request, _, _, _}}},
                   5_000

    assert waiter_pid == waiter.pid
    assert length(:sys.get_state(manager).history[server_id].waiters) == 1
    assert Task.yield(waiter, 0) == nil
    assert :sys.get_state(manager).history[server_id].cursors == ledger.cursors
    send(writer, :release_boundary_persistence)
    {next, context} = Task.await(waiter, 5_000)
    delivered = await_delivery_event()
    assert_receive {:DOWN, ^delivery_monitor, :process, _, _}, 5_000
    assert next.token != ledger.lease.token

    assert Enum.count(
             context.entries,
             &(&1.refs[:message_id] == delivered.metadata.assistant_message_id)
           ) == 1

    assert Enum.count(
             context.entries,
             &String.contains?(to_string(&1.content), "During persistence background")
           ) == 1

    assert Repo.get_by!(ExecutionRecord, user_message_id: root.id).status == "completed"
    assert next.cursors[placement.transcript_id] > ledger.cursors[placement.transcript_id]
    :telemetry.detach(handler)
  end

  @tag :boundary_revocation
  @tag :authorized_execution
  test "a revoked boundary read disposes warm state without discarding the persisted answer",
       ctx do
    resource = ChannelHistoryResource.for("mattermost", ctx.config.id, "shared-room")

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "boundary-revoked-root",
               "message" => "@zaq A single final answer"
             })

    assert_receive {:history_llm, _request}, 5_000
    assert_receive {:history_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_history_llm) end)
    root = Repo.get_by!(Message, external_message_id: "boundary-revoked-root")
    placement = Repo.get_by!(TranscriptMessage, message_id: root.id)
    server_id = "#{ctx.agent.name}:history:#{placement.transcript_id}:person:#{ctx.person.id}"
    ledger = :sys.get_state(ServerManager).history[server_id]
    assert is_pid(ledger.pid)
    monitor = Process.monitor(ledger.pid)
    delivery_monitor = Process.monitor(ledger.lease.owner)
    permission = actual_provider_permission(resource, ctx.person)
    assert :ok = Zaq.Permissions.revoke(resource, permission)
    refute Zaq.Permissions.can?(ctx.person, "read", resource)
    send(worker, :release_history_llm)
    delivered = await_delivery_event()
    assert delivered.body == "History answer"
    execution = Repo.get_by!(ExecutionRecord, user_message_id: root.id)
    assert execution.status == "completed"
    assert execution.public_answer_message_id == delivered.metadata.assistant_message_id
    assert Repo.get!(Message, execution.public_answer_message_id).content == delivered.body
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert_receive {:DOWN, ^delivery_monitor, :process, _, _}, 5_000
    assert :sys.get_state(ServerManager).history[server_id] == nil
    refute_received {:history_llm, _}
  end

  @tag :per_turn_refresh
  @tag :authorized_execution
  test "three real internal turns reread cumulative A then A+B while preserving both tool pairs",
       ctx do
    assert {:ok, _} =
             Zaq.Permissions.grant(
               ChannelHistoryResource.for("mattermost", ctx.config.id, "shared-room"),
               %{person_id: ctx.person.id, access_rights: ["read"]}
             )

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "cumulative-root",
               "message" => "@zaq history question"
             })

    assert_receive {:history_llm, initial}, 5_000
    assert_receive {:history_llm_barrier, first_worker}, 5_000
    on_exit(fn -> send(first_worker, :release_history_llm) end)
    refute Jason.encode!(initial["input"]) =~ "Cumulative background"
    assert Repo.get_by(Message, external_message_id: "root-human") == nil

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", false, %{
               "id" => "cumulative-a",
               "message" => "Cumulative background A"
             })

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, nil, false, %{
               "id" => "root-human",
               "message" => "Late retained root",
               "create_at" => 1_600_000_000_000
             })

    send(first_worker, :release_history_llm)

    assert_receive {:history_llm, second}, 5_000
    assert_receive {:history_llm_barrier, second_worker}, 5_000
    on_exit(fn -> send(second_worker, :release_history_llm) end)
    second_input = Jason.encode!(second["input"])
    assert length(Regex.scan(~r/Cumulative background A/, second_input)) == 1
    assert length(Regex.scan(~r/Late retained root/, second_input)) == 1
    refute second_input =~ "Cumulative background B"

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", false, %{
               "id" => "cumulative-b",
               "message" => "Cumulative background B"
             })

    send(second_worker, :release_history_llm)

    assert_receive {:history_llm, third}, 5_000
    third_input = Jason.encode!(third["input"])
    assert length(Regex.scan(~r/Cumulative background A/, third_input)) == 1
    assert length(Regex.scan(~r/Cumulative background B/, third_input)) == 1
    assert length(Regex.scan(~r/Late retained root/, third_input)) == 1
    assert length(Regex.scan(~r/history question/, third_input)) == 1
    assert third_input =~ "Author: \\\"Alice\\\" [person:#{ctx.person.id}]"
    [system, root_entry, a, b, current, call1, output1, call2, output2] = third["input"]
    assert system == List.first(initial["input"])
    assert current == List.last(initial["input"])
    assert root_entry == Enum.at(second["input"], 1)
    assert a == Enum.at(second["input"], 2)

    assert MultiAgentOpenAIStub.latest_user_message(%{"input" => [b]}) ==
             "Author: \"Alice\" [person:#{ctx.person.id}]\nSent at: 2023-11-14 22:13:20Z\nMessage:\nCumulative background B"

    for {call, output, id, arguments, result} <- [
          {call1, output1, "refresh-call-1", %{"value" => 2, "amount" => 3}, 5.0},
          {call2, output2, "refresh-call-2", %{"value" => 3, "amount" => 4}, 7.0}
        ] do
      assert call["type"] == "function_call"
      assert call["call_id"] == id
      assert Jason.decode!(call["arguments"]) == arguments
      assert output["type"] == "function_call_output"
      assert output["call_id"] == id
      assert Jason.decode!(output["output"]) == %{"ok" => true, "result" => %{"result" => result}}
    end

    transcript = Repo.get_by!(Transcript, external_thread_id: "root-human")
    answer = await_answer(transcript.id)
    assert answer.content == "Cumulative history answer"
    root = Repo.get_by!(Message, external_message_id: "cumulative-root")
    late_root = Repo.get_by!(Message, external_message_id: "root-human")
    assert DateTime.compare(late_root.provider_sent_at, root.provider_sent_at) == :lt
    execution = Repo.get_by!(ExecutionRecord, user_message_id: root.id)
    assert execution.status == "completed"
    assert execution.public_answer_message_id == answer.id
    assert execution.usage["prompt_tokens"] == 15
    assert execution.usage["completion_tokens"] == 3
    assert length(execution.tool_results) == 2
    assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 1
    assert Repo.aggregate(ExecutionRecord, :count) == 1
    delivered = await_delivery_event()
    assert delivered.metadata.assistant_message_id == answer.id
    scope = "history:#{transcript.id}:person:#{ctx.person.id}"
    server_id = "#{ctx.agent.name}:#{scope}"
    ledger = :sys.get_state(ServerManager).history[server_id]
    assert ledger.lease == nil
    assert {:ok, %{raw_state: %{__strategy__: strategy}}} = Jido.AgentServer.status(ledger.pid)
    entries = strategy.context.entries

    for id <- [
          root.id,
          late_root.id,
          answer.id,
          Repo.get_by!(Message, external_message_id: "cumulative-a").id,
          Repo.get_by!(Message, external_message_id: "cumulative-b").id
        ] do
      assert Enum.count(entries, &(&1.refs[:message_id] == id)) == 1,
             "missing or duplicated #{id}; refs=#{inspect(Enum.map(entries, & &1.refs))}"
    end

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", false, %{
               "id" => "boundary-d",
               "message" => "After completion background D"
             })

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "boundary-next",
               "message" => "@zaq Next warm question"
             })

    assert_receive {:history_llm, next_request}, 5_000
    next_input = Jason.encode!(next_request["input"])

    for text <- [
          "Cumulative background A",
          "Cumulative background B",
          "Late retained root",
          "After completion background D",
          "history question",
          "Next warm question",
          "Cumulative history answer"
        ] do
      assert length(Regex.scan(Regex.compile!(Regex.escape(text)), next_input)) == 1
    end

    assert length(MultiAgentOpenAIStub.tool_results(next_request)) == 2
    next_delivery = await_delivery_event()
    refute next_delivery.metadata.assistant_message_id == answer.id
    next_ledger = :sys.get_state(ServerManager).history[server_id]
    assert next_ledger.pid == ledger.pid
    assert next_ledger.lease == nil
    assert Enum.all?(ledger.cursors, fn {id, cursor} -> next_ledger.cursors[id] >= cursor end)
    assert Repo.aggregate(ExecutionRecord, :count) == 2
  end

  @tag :refresh_budget
  @tag :authorized_execution
  @tag :input_consumption
  test "steering plus refreshed budget pressure preserves the whole active two-tool execution",
       ctx do
    assert {:ok, _} =
             Zaq.Permissions.grant(
               ChannelHistoryResource.for("mattermost", ctx.config.id, "shared-room"),
               %{person_id: ctx.person.id, access_rights: ["read"]}
             )

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "budget-refresh-root",
               "message" => "@zaq history question"
             })

    assert_receive {:history_llm, initial}, 5_000
    assert_receive {:history_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_history_llm) end)
    content = String.duplicate("EVICTABLE_REFRESH_BACKGROUND ", 2_000)

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", false, %{
               "id" => "budget-background",
               "message" => content
             })

    for index <- 1..2 do
      assert {{:ok, _}, _} =
               MattermostHistoryFixture.post(ctx.config, "human", true, %{
                 "id" => "budget-correction-#{index}",
                 "message" => "@zaq Preserve the original task correction #{index}"
               })

      assert_receive :history_input_queued, 5_000
    end

    send(worker, :release_history_llm)
    assert_receive {:history_llm, second}, 5_000
    assert_receive {:history_llm, third}, 5_000

    for request <- [second, third] do
      refute Jason.encode!(request["input"]) =~ "EVICTABLE_REFRESH_BACKGROUND"
      assert List.first(request["input"]) == List.first(initial["input"])
      assert Enum.at(request["input"], 1) == List.last(initial["input"])
      payload = Jason.encode!(request["input"])

      for index <- 1..2 do
        assert length(
                 Regex.scan(
                   Regex.compile!("Preserve the original task correction #{index}"),
                   payload
                 )
               ) == 1
      end
    end

    [call1, output1, call2, output2] =
      Enum.filter(third["input"], &(&1["type"] in ["function_call", "function_call_output"]))

    assert call1["type"] == "function_call"
    assert output1["type"] == "function_call_output"
    assert call1["call_id"] == output1["call_id"]
    assert call1["call_id"] == "refresh-call-1"
    assert call2["type"] == "function_call"
    assert output2["type"] == "function_call_output"
    assert call2["call_id"] == output2["call_id"]
    assert call2["call_id"] == "refresh-call-2"
    transcript = Repo.get_by!(Transcript, external_thread_id: "root-human")
    answer = await_answer(transcript.id)
    assert answer.content == "Cumulative history answer"
    assert Repo.get_by!(Message, external_message_id: "budget-background").content == content
    assert Repo.aggregate(ExecutionRecord, :count) == 3

    for index <- 1..2 do
      input = Repo.get_by!(Message, external_message_id: "budget-correction-#{index}")
      assert Repo.get_by!(ExecutionRecord, user_message_id: input.id).status == "consumed"
    end

    assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 1
  end

  defp history_llm_handler(tags, owner) do
    cond do
      tags[:delayed_terminal] ->
        fn _conn, body ->
          request = Jason.decode!(body)
          {200, MultiAgentOpenAIStub.text_sse(delayed_terminal_answer(), request["model"])}
        end

      terminal_boundary?(tags) ->
        fn _conn, body ->
          request = Jason.decode!(body)
          {200, MultiAgentOpenAIStub.text_sse("History answer", request["model"])}
        end

      cumulative_refresh?(tags) ->
        &cumulative_refresh_response/2

      tags[:root_failure] ->
        fn _conn, _body -> {400, %{"error" => %{"message" => "Scripted rejection"}}} end

      tags[:queue_overflow] ->
        fn _conn, body ->
          request = Jason.decode!(body)
          {200, MultiAgentOpenAIStub.text_sse("Sealed root answer", request["model"])}
        end

      tags[:input_consumption] ->
        consumption_llm_handler(owner, tags[:steering_mode] == :attachment_control)

      tags[:authorized_execution] ->
        ToolCallingLLMStub.handler(
          routes: [
            %{
              match: &String.contains?(&1, "history question"),
              tool: "add",
              arguments: fn _ -> %{value: 2, amount: 3} end
            }
          ],
          final_response: "History answer"
        )

      true ->
        nil
    end
  end

  defp delayed_terminal_answer, do: "هذا هو الجواب الكامل، وليس تحديثاً جزئياً."

  defp delivery_http(tags, conn, body, owner, counter) do
    payload = if body == "", do: %{}, else: Jason.decode!(body)

    terminal? =
      conn.method in ["PUT", "POST"] and
        String.starts_with?(conn.request_path, "/api/v4/posts") and
        payload["message"] == delayed_terminal_answer()

    final? = tags[:delayed_terminal] && terminal? && :atomics.add_get(counter, 1, 1) > 1

    if final? do
      send(owner, {:terminal_transport_barrier, self(), payload})

      receive do
        :release_terminal_transport -> :ok
      after
        120_000 -> flunk("terminal transport barrier was not released")
      end

      if tags[:transport_timeout],
        do: {504, %{"message" => "Gateway Timeout"}},
        else: MattermostHistoryFixture.http(conn, body, owner)
    else
      MattermostHistoryFixture.http(conn, body, owner)
    end
  end

  @tag :delayed_terminal
  @tag :transport_receive_timeout
  @tag timeout: 120_000
  test "a real asynchronous terminal HTTP receive timeout retains generation without a false confirmation",
       ctx do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "terminal-receive-timeout",
               "message" => "@zaq Answer completely"
             })

    assert_receive {:history_execution_completed, owner}, 5_000
    owner_monitor = Process.monitor(owner)
    assert_receive {:terminal_transport_barrier, transport, payload}, 5_000
    on_exit(fn -> send(transport, :release_terminal_transport) end)
    assert payload["message"] == delayed_terminal_answer()
    input = Repo.get_by!(Message, external_message_id: "terminal-receive-timeout")
    record = Repo.get_by!(ExecutionRecord, user_message_id: input.id)
    assert record.status == "completed"
    answer = Repo.get!(Message, record.public_answer_message_id)
    refute Repo.exists?(from p in TranscriptMessage, where: p.message_id == ^answer.id)
    # Do not release the external response: exercise the real Req deadline and
    # native adapter error, not a hand-built timeout receipt or persisted flag.
    assert_receive {:DOWN, ^owner_monitor, :process, _, _}, 100_000
    assert Repo.get!(ExecutionRecord, record.id).status == "completed"
    assert Repo.get!(Message, answer.id).content == delayed_terminal_answer()
    assert {:error, :missing_confirmation} = HistoryIngress.associate_confirmation(answer.id)
    refute Repo.exists?(from p in TranscriptMessage, where: p.message_id == ^answer.id)
    refute Repo.exists?(from j in Oban.Job, where: j.worker == "Zaq.Engine.HistoryDeliveryWorker")
    # Release any late HTTP/retry handlers only after the caller has timed out.
    # Their eventual server-side success cannot become a transport confirmation.
    send(transport, :release_terminal_transport)
    release_terminal_handlers()
    assert {:error, :missing_confirmation} = HistoryIngress.associate_confirmation(answer.id)
  end

  defp release_terminal_handlers do
    receive do
      {:terminal_transport_barrier, transport, _} ->
        send(transport, :release_terminal_transport)
        release_terminal_handlers()
    after
      0 -> :ok
    end
  end

  for timeout? <- [false, true] do
    @tag :delayed_terminal
    @tag transport_timeout: timeout?
    test "asynchronous generation awaits delayed terminal #{if timeout?, do: "gateway timeout", else: "confirmation"}",
         ctx do
      assert {{:ok, _}, _} =
               MattermostHistoryFixture.post(ctx.config, "human", true, %{
                 "id" => "delayed-terminal-input",
                 "message" => "@zaq Answer completely"
               })

      assert_receive {:history_execution_completed, owner}, 5_000
      owner_monitor = Process.monitor(owner)
      assert_receive {:terminal_transport_barrier, transport, payload}, 5_000
      on_exit(fn -> send(transport, :release_terminal_transport) end)
      assert payload["message"] == delayed_terminal_answer()
      input = Repo.get_by!(Message, external_message_id: "delayed-terminal-input")
      record = Repo.get_by!(ExecutionRecord, user_message_id: input.id)
      assert record.status == "completed"
      assert record.public_answer_message_id
      answer = Repo.get!(Message, record.public_answer_message_id)
      assert answer.content == delayed_terminal_answer()
      refute Repo.exists?(from p in TranscriptMessage, where: p.message_id == ^answer.id)
      refute_receive {:DOWN, ^owner_monitor, :process, _, _}, 0
      send(transport, :release_terminal_transport)
      assert_receive {:DOWN, ^owner_monitor, :process, _, _}, 10_000
      assert Repo.get!(ExecutionRecord, record.id).status == "completed"
      assert Repo.get!(Message, answer.id).content == delayed_terminal_answer()

      if ctx.transport_timeout do
        refute Repo.exists?(from p in TranscriptMessage, where: p.message_id == ^answer.id)
        assert {:error, :missing_confirmation} = HistoryIngress.associate_confirmation(answer.id)

        refute Repo.exists?(
                 from j in Oban.Job, where: j.worker == "Zaq.Engine.HistoryDeliveryWorker"
               )
      else
        assert Repo.exists?(
                 from p in TranscriptMessage,
                   where: p.message_id == ^answer.id and p.provenance == "provider_confirmed"
               )

        assert {:ok, _} = HistoryIngress.associate_confirmation(answer.id)

        assert Repo.aggregate(
                 from(p in TranscriptMessage, where: p.message_id == ^answer.id),
                 :count
               ) == 1
      end

      refute_received {:terminal_transport_barrier, _, _}
    end
  end

  defp cumulative_refresh?(tags),
    do: Enum.any?([:per_turn_refresh, :refresh_revocation, :refresh_budget], &(tags[&1] == true))

  @tag :refresh_revocation
  @tag :authorized_execution
  @tag :per_turn_refresh
  test "revoked grants deny fresh history while the accepted real model/tool loop completes",
       ctx do
    resource = ChannelHistoryResource.for("mattermost", ctx.config.id, "shared-room")

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "revoked-refresh-root",
               "message" => "@zaq history question"
             })

    assert_receive {:history_llm, _initial}, 5_000
    assert_receive {:history_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_history_llm) end)

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", false, %{
               "id" => "authorized-delta",
               "message" => "Already authorized addition"
             })

    send(worker, :release_history_llm)
    assert_receive {:history_llm, second}, 5_000
    assert Jason.encode!(second["input"]) =~ "Already authorized addition"
    assert_receive {:history_llm_barrier, next_worker}, 5_000
    on_exit(fn -> send(next_worker, :release_history_llm) end)
    permission = actual_provider_permission(resource, ctx.person)
    assert :ok = Zaq.Permissions.revoke(resource, permission)
    refute Zaq.Permissions.can?(ctx.person, "read", resource)

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, nil, false, %{
               "id" => "forbidden-delta",
               "message" => "Forbidden fresh addition"
             })

    send(next_worker, :release_history_llm)
    assert_receive {:history_llm, next_turn}, 5_000
    assert length(MultiAgentOpenAIStub.tool_results(next_turn)) == 2

    assert length(Regex.scan(~r/Already authorized addition/, Jason.encode!(next_turn["input"]))) ==
             1

    refute Jason.encode!(next_turn["input"]) =~ "Forbidden fresh addition"
    assert_receive {:history_execution_completed, writer}, 5_000
    monitor = Process.monitor(writer)
    assert_receive {:DOWN, ^monitor, :process, ^writer, reason}, 5_000
    assert reason in [:normal, :noproc]
    refute_receive {:history_llm, _}, 0
    input = Repo.get_by!(Message, external_message_id: "revoked-refresh-root")
    execution = Repo.get_by!(ExecutionRecord, user_message_id: input.id)
    assert execution.status == "completed"
    assert %DateTime{} = execution.admitted_at
    answer = Repo.get!(Message, execution.public_answer_message_id)
    assert answer.content == "Cumulative history answer"
    assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 1
    assert Repo.get!(Message, input.id).content == "@zaq history question"
  end

  defp actual_provider_permission(resource, person) do
    permission =
      Enum.find(Zaq.Permissions.list_direct(resource), fn permission ->
        permission.person_id == person.id and
          permission.source_key == "channel_history:provider:mattermost"
      end)

    assert permission, "real ingress must establish provider-derived sender access"
    assert Zaq.Permissions.can?(person, "read", resource)
    permission
  end

  defp terminal_boundary?(tags),
    do: Enum.any?([:membership_removal, :boundary_revocation, :boundary_persistence], &tags[&1])

  defp history_barrier?(%{per_turn_refresh: true}, request, _body),
    do: length(MultiAgentOpenAIStub.tool_results(request)) < 2

  defp history_barrier?(tags, request, body),
    do:
      tags[:input_consumption] == true and not String.contains?(body, "function_call_output") and
        (tags[:queue_overflow] != true or not Map.has_key?(request, "previous_response_id"))

  defp cumulative_refresh_response(_conn, body) do
    request = Jason.decode!(body)

    case length(MultiAgentOpenAIStub.tool_results(request)) do
      0 ->
        {200,
         MultiAgentOpenAIStub.tool_call_sse("add", %{value: 2, amount: 3},
           model: request["model"],
           call_id: "refresh-call-1",
           fc_id: "refresh-fc-1"
         )}

      1 ->
        {200,
         MultiAgentOpenAIStub.tool_call_sse("add", %{value: 3, amount: 4},
           model: request["model"],
           call_id: "refresh-call-2",
           fc_id: "refresh-fc-2"
         )}

      2 ->
        {200, MultiAgentOpenAIStub.text_sse("Cumulative history answer", request["model"])}
    end
  end

  defp assert_failed_receipt_persistence(ctx, request_id, actor) do
    input =
      Incoming.new(%{
        content: "@zaq persistence-failed correction",
        channel_id: "shared-room",
        author_id: "alice",
        message_id: "persistence-failed-input",
        thread_id: "root-human",
        provider: :mattermost,
        person: ctx.person,
        routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
      })
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    provisional = Repo.get!(ExecutionRecord, binding.execution_id)
    assert provisional.admitted_at == nil
    assert {:ok, _} = Conversations.admit_execution(binding, actor, input.content)
    before = Repo.get!(ExecutionRecord, binding.execution_id)
    assert %DateTime{} = before.admitted_at
    assert %{before | admitted_at: nil, updated_at: provisional.updated_at} == provisional
    # A real, UUID-scoped database failure. This file is serial and the blocked
    # external LLM owns no transaction; no runtime/persistence mocks are involved.
    SQL.query!(Repo, """
    ALTER TABLE execution_records ADD CONSTRAINT receipt_failure_boundary_test
    CHECK (id <> '#{before.id}'::uuid OR status <> 'queued')
    """)

    try do
      event =
        Zaq.Event.new(
          %{request_id: request_id, content: input.content, conversation_binding: binding},
          :agent,
          actor: actor
        )

      assert %{response: {:error, :execution_persistence_failed}} =
               Zaq.Agent.Api.handle_event(event, :steer_request, nil)

      assert Repo.get!(ExecutionRecord, before.id) == before
      assert Repo.get!(Message, binding.user_message_id).content == input.content
    after
      SQL.query!(
        Repo,
        "ALTER TABLE execution_records DROP CONSTRAINT receipt_failure_boundary_test"
      )
    end
  end

  defp assert_rejected_control_receipt(ctx, _state, actor) do
    # A nonexistent native ID is rejected before queueing, without fabricating
    # application-owned bindings. Completion-after-queue is covered separately.
    stale_id = "stale-control-#{System.unique_integer([:positive])}"

    input =
      Incoming.new(%{
        content: "@zaq Rejected correction",
        channel_id: "shared-room",
        author_id: "alice",
        message_id: "rejected-correction",
        thread_id: "root-human",
        provider: :mattermost,
        person: ctx.person,
        routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
      })
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)

    event =
      Zaq.Event.new(
        %{request_id: stale_id, content: input.content, conversation_binding: binding},
        :agent,
        actor: actor
      )

    assert %{response: {:error, :not_found}} =
             Zaq.Agent.Api.handle_event(event, :steer_request, nil)

    receipt = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)
    assert receipt.status == "pending"
    assert receipt.root_execution_id == nil
    assert receipt.public_answer_message_id == nil
  end

  defp consumption_llm_handler(owner, attachment?) do
    state = start_supervised!({Agent, fn -> :initial end}, id: make_ref())
    args = %{"value" => 2, "amount" => 3}
    call_id = "receipt-call-#{System.unique_integer([:positive])}"

    fn _conn, body ->
      request = Jason.decode!(body)

      Agent.get_and_update(state, fn
        :initial ->
          send(owner, {:llm_tool_call, "add", args})

          response =
            MultiAgentOpenAIStub.tool_call_sse("add", args,
              model: request["model"],
              call_id: call_id
            )

          {{200, response}, {:continuation, request["input"]}}

        {:continuation, initial} ->
          history_length = length(initial) - 1
          assert Enum.take(request["input"], history_length) == Enum.take(initial, history_length)

          [rejected, failed_persistence, passive, current] =
            request["input"] |> Enum.drop(history_length) |> Enum.take(4)

          assert_message_content(
            MultiAgentOpenAIStub.latest_user_message(%{"input" => [rejected]}),
            "Alice",
            "@zaq Rejected correction"
          )

          assert_message_content(
            MultiAgentOpenAIStub.latest_user_message(%{"input" => [failed_persistence]}),
            "Alice",
            "@zaq persistence-failed correction"
          )

          assert_message_content(
            MultiAgentOpenAIStub.latest_user_message(%{"input" => [passive]}),
            "Bob",
            "Passive refresh A"
          )

          assert current == List.last(initial)
          [call, output, correction] = Enum.drop(request["input"], history_length + 4)
          assert call["type"] == "function_call"
          assert call["call_id"] == call_id
          assert call["name"] == "add"
          assert Jason.decode!(call["arguments"]) == args
          assert output["type"] == "function_call_output"
          assert output["call_id"] == call_id

          content = MultiAgentOpenAIStub.latest_user_message(%{"input" => [correction]})

          assert_correction_content(content, attachment?)

          [result] = MultiAgentOpenAIStub.tool_results(request)
          send(owner, {:llm_tool_result, "add", result.output})
          {{200, MultiAgentOpenAIStub.text_sse("History answer", request["model"])}, :done}
      end)
    end
  end

  defp await_delivery_event do
    receive do
      {:node_router_event, %Zaq.Event{opts: opts, request: %Outgoing{} = outgoing}} ->
        if opts[:action] == :deliver_outgoing, do: outgoing, else: await_delivery_event()
    after
      5_000 -> flunk("no real Engine delivery event was observed")
    end
  end

  defp assert_correction_content(content, true) do
    [message, metadata] =
      String.split(content, "\nAttachments:\n")

    assert_message_content(message, "Alice", "@zaq Retain the arithmetic tool result")

    [record] = Jason.decode!(metadata)
    assert record["name"] == "correction.pdf"
    assert String.starts_with?(record["materialization_handle"], "mat_")
  end

  defp assert_correction_content(content, false),
    do: assert_message_content(content, "Alice", "@zaq Retain the arithmetic tool result")

  defp assert_message_content(content, name, body) do
    assert [header, timestamp, "Message:", ^body] = String.split(content, "\n", parts: 4)
    assert header =~ ~r/\AAuthor: #{Regex.escape(Jason.encode!(name))} \[person:[1-9]\d*\]\z/
    assert timestamp =~ ~r/\A(?:Sent|Recorded) at: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z\z/
  end

  defp observe_history_commit(owner) do
    handler = {__MODULE__, owner}

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ ->
        observe_history_query(metadata, owner, handler)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp observe_history_query(metadata, owner, handler) do
    if self() != owner do
      cond do
        failed_execution_query?(metadata) ->
          Process.put({handler, :failed_execution}, true)

        completed_execution_query?(metadata) ->
          Process.put({handler, :completed_execution}, true)

        queued_record_query?(metadata) ->
          Process.put({handler, :receipt}, true)

        confirmed_placement_query?(metadata) ->
          Process.put(handler, true)

        metadata.query == "commit" ->
          notify_history_commit(owner, handler)

        true ->
          :ok
      end
    end
  end

  defp notify_history_commit(owner, handler) do
    flags = [
      {handler, {:history_placement_committed, self()}},
      {{handler, :receipt}, :history_input_queued},
      {{handler, :failed_execution}, {:history_execution_failed, self()}},
      {{handler, :completed_execution}, {:history_execution_completed, self()}}
    ]

    Enum.each(flags, fn {key, message} ->
      if Process.delete(key), do: send(owner, message)
    end)
  end

  defp failed_execution_query?(metadata),
    do:
      metadata[:source] == "execution_records" and String.starts_with?(metadata.query, "UPDATE") and
        "failed" in (metadata[:cast_params] || [])

  defp completed_execution_query?(metadata),
    do:
      metadata[:source] == "execution_records" and String.starts_with?(metadata.query, "UPDATE") and
        "completed" in (metadata[:cast_params] || [])

  defp queued_record_query?(metadata),
    do:
      metadata[:source] == "execution_records" and String.starts_with?(metadata.query, "UPDATE") and
        "queued" in (metadata[:cast_params] || [])

  defp confirmed_placement_query?(metadata),
    do:
      metadata[:source] == "transcript_messages" and String.starts_with?(metadata.query, "INSERT") and
        "provider_confirmed" in (metadata[:cast_params] || [])

  defp await_answer(transcript_id) do
    assert_receive {:history_placement_committed, writer}, 5_000
    monitor = Process.monitor(writer)
    assert_receive {:DOWN, ^monitor, :process, ^writer, reason}, 5_000
    assert reason in [:normal, :noproc]

    Repo.one!(
      from m in Message,
        join: p in TranscriptMessage,
        on: p.message_id == m.id,
        where: p.transcript_id == ^transcript_id and m.role == "assistant",
        select: m
    )
  end
end
