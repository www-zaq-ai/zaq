defmodule Zaq.Channels.MattermostSharedHistoryIntegrationTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts.People
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.{ChannelConfig, JidoChatBridge}
  alias Zaq.Channels.MattermostAdmin
  alias Zaq.Engine.Api
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, Transcript, TranscriptMessage}
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.TestSupport.{MattermostHistoryFixture, OpenAIStub}

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

  setup do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    owner = self()
    observe_history_commit(owner)
    previous = Map.new(@keys, &{&1, Application.fetch_env(:zaq, &1)})
    Enum.each(@keys, &Application.delete_env(:zaq, &1))

    Application.put_env(:zaq, :channels, %{
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

    {child, endpoint} = OpenAIStub.server(&MattermostHistoryFixture.http(&1, &2, owner), owner)
    start_supervised!(child)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "History Agent #{System.unique_integer([:positive])}",
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
             MattermostAdmin.history_root(ctx.config, "another-room", "root-human")
  end

  defp await_delivery_event do
    receive do
      {:node_router_event, %Zaq.Event{opts: opts, request: %Outgoing{} = outgoing}} ->
        if opts[:action] == :deliver_outgoing, do: outgoing, else: await_delivery_event()
    after
      5_000 -> flunk("no real Engine delivery event was observed")
    end
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
        metadata[:source] == "transcript_messages" and
          String.starts_with?(metadata.query, "INSERT") and
            "provider_confirmed" in (metadata[:cast_params] || []) ->
          Process.put(handler, true)

        metadata.query == "commit" and Process.delete(handler) ->
          send(owner, {:history_placement_committed, self()})

        true ->
          :ok
      end
    end
  end

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
