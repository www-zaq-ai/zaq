defmodule Zaq.Engine.WhatsAppThreadHistoryTest do
  use Zaq.DataCase, async: false

  alias Jido.AgentServer
  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Accounts.People
  alias Zaq.Agent.{Executor, HistoryLoader, HistorySync, ServerManager}
  alias Zaq.Channels.{CommunicationBridge, JidoChatBridge}
  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Api, as: EngineApi
  alias Zaq.Engine.{ChannelHistoryMembership, Conversations, HistoryIngress}
  alias Zaq.Engine.Conversations.{Message, Transcript}
  alias Zaq.Event
  alias Zaq.Materialization.Handle
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.TestSupport.{IntegrationAgent, MultiAgentOpenAIStub, OpenAIStub}

  setup do
    config = connector()
    {:ok, person} = People.create_person(%{full_name: "Thread author"})
    add_identity(person, config)
    %{config: config, person: person}
  end

  test "adapter reply target selects captured root and thread history exactly once", ctx do
    root = incoming(ctx, "root", nil, "ROOT_HISTORY_CONTENT")
    assert {:ok, root_capture} = HistoryIngress.capture(root)
    grant(ctx)
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, "local", "root", "LOCAL_CONTENT"))
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, "sibling", "other", "SIBLING_SECRET"))

    {input, _binding, projection} = project(ctx, "question", "root")
    assert input.thread_id == "root"

    assert Enum.map(projection.messages, & &1.content) == [
             "ROOT_HISTORY_CONTENT",
             "LOCAL_CONTENT"
           ]

    assert Enum.count(projection.messages, &(&1.message_id == root_capture.message_id)) == 1
    assert Repo.get!(Transcript, projection.transcript_id).external_thread_id == "root"

    context = HistoryLoader.from_projection(projection.messages)
    assert Enum.any?(context.entries, &String.contains?(&1.content, "ROOT_HISTORY_CONTENT"))
    refute inspect(context) =~ "INLINE_COPY"
    refute inspect(context) =~ "SIBLING_SECRET"
  end

  test "missing originals leave available thread history intact without using inline text", ctx do
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, "local", "missing", "LOCAL_CONTENT"))
    grant(ctx)
    {_input, _binding, projection} = project(ctx, "question", "missing")
    assert Enum.map(projection.messages, & &1.content) == ["LOCAL_CONTENT"]
  end

  test "root attachments use their authorized parent placement and lazy handles", ctx do
    source =
      CommunicationMedia.source_metadata("whatsapp", "root-file", %{
        "channel_config_id" => ctx.config.id,
        "source_author_id" => "author@s.whatsapp.net",
        "source_channel_id" => "room@g.us",
        "source_message_id" => "root"
      })

    root = %{
      incoming(ctx, "root", nil, "Root image")
      | attachments: [
          %Record{
            id: "root-file",
            name: "root.png",
            kind: :file,
            attributes: %{"materialization_source" => source}
          }
        ]
    }

    assert {:ok, captured} = HistoryIngress.capture(root)
    grant(ctx)
    {_input, binding, _projection} = project(ctx, "question", "root")
    event = Event.new(binding, :engine, actor: actor(ctx), opts: [confidential: true])
    assert %{response: {:ok, projection}} = EngineApi.handle_event(event, :execution_history, %{})
    assert [%{attachments: [attachment]}] = projection.messages
    assert {:ok, %{locator: locator}} = Handle.verify(attachment["materialization_handle"])
    assert locator["canonical_attachment"]["message_id"] == captured.message_id
    assert locator["canonical_attachment"]["transcript_id"] == captured.transcript_id
    assert captured.transcript_id != projection.transcript_id
    assert attachment["name"] == "root.png"
    refute Map.has_key?(attachment, "content")
  end

  test "same external root ID in another connector or room does not supply context", ctx do
    other = %{ctx | config: connector()}
    add_identity(ctx.person, other.config)
    assert {:ok, _} = HistoryIngress.capture(incoming(other, "root", nil, "CONNECTOR_SECRET"))

    assert {:ok, _} =
             HistoryIngress.capture(incoming(ctx, "root", nil, "ROOM_SECRET", "other@g.us"))

    grant(ctx)
    {_input, _binding, projection} = project(ctx, "question", "root")
    assert projection.messages == []
  end

  test "a revoked room grant denies history rather than following the root reference", ctx do
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, "root", nil, "PRIVATE_ROOT"))
    {:ok, permission} = grant(ctx)
    {_input, binding, _projection} = project(ctx, "question", "root")

    assert {:ok, _} =
             ChannelHistoryMembership.apply_event(%{
               provider: "whatsapp",
               channel_config_id: ctx.config.id,
               channel_id: "room@g.us",
               identity_platform: "whatsapp",
               member_id: "author@s.whatsapp.net",
               operation: :remove,
               revision: 1
             })

    assert :ok = Permissions.revoke(resource(ctx), permission)
    refute Permissions.can?(ctx.person, :read, resource(ctx))
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx))
  end

  test "reply-to-reply IDs select separate immediate-target transcripts", ctx do
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, "A", nil, "ROOT_A"))
    assert {:ok, first} = HistoryIngress.capture(incoming(ctx, "B", "A", "REPLY_B"))
    grant(ctx)
    {_input, _binding, projection} = project(ctx, "C", "B")
    assert projection.transcript_id != first.transcript_id
    assert Repo.get!(Transcript, projection.transcript_id).external_thread_id == "B"
    # B lives in A's child transcript. Existing parent lookup does not traverse siblings.
    assert Enum.map(projection.messages, & &1.content) == ["ROOT_A"]
  end

  test "DM replies use child transcripts, retain root history and deduplicate stored messages",
       ctx do
    room = "123@s.whatsapp.net"
    assert {:ok, root} = HistoryIngress.capture(incoming(ctx, "root", nil, "DM_ROOT", room))
    input = incoming(ctx, "question", "root", "Question", room)
    assert {:ok, first} = HistoryIngress.capture(input)
    assert {:ok, second} = HistoryIngress.capture(input)
    assert first.message_id == second.message_id
    assert first.transcript_id == second.transcript_id
    assert first.transcript_id != root.transcript_id
    assert Repo.get!(Transcript, first.transcript_id).external_thread_id == "root"
    assert {:ok, binding} = Conversations.admit_incoming(input)
    assert {:ok, projection} = Conversations.execution_history(binding, actor(ctx))
    assert projection.transcript_id == first.transcript_id
    assert Enum.map(projection.messages, & &1.content) == ["DM_ROOT"]
  end

  test "captured root content reaches the real agent on cold and warm execution", ctx do
    owner = self()

    handler = fn _conn, body ->
      send(owner, {:model_input, body})
      {200, MultiAgentOpenAIStub.text_sse("Thread answer", "gpt-4.1-mini")}
    end

    {child, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(child)
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, "root", nil, "ROOT_HISTORY_CONTENT"))
    grant(ctx)
    first = project(ctx, "question-1", "root")
    {_input, _binding, projection} = first
    scope = "history:#{projection.transcript_id}:person:#{ctx.person.id}"
    agent = IntegrationAgent.create!(endpoint, scope, "Answer the thread question.", [])
    on_exit(fn -> ServerManager.stop_server(agent) end)

    runtimes =
      for attempt <- 1..2 do
        if attempt == 2 do
          assert {:ok, _} =
                   HistoryIngress.capture(incoming(ctx, "later", "root", "LATER_HISTORY_CONTENT"))
        end

        {input, binding, _projection} =
          if attempt == 1, do: first, else: project(ctx, "question-#{attempt}", "root")

        event = Event.new(input, :agent, actor: actor(ctx))

        outgoing =
          HistorySync.with_session(fn session ->
            result =
              Executor.run(input,
                agent_id: to_string(agent.id),
                scope: scope,
                conversation_binding: binding,
                event: event,
                history_session: session
              )

            assert result.metadata.error == false

            assert {:ok, persisted} =
                     Conversations.finalize_incoming(
                       binding.user_message_id,
                       binding.finalization_token,
                       %{answer: result.body, usage: %{}, error: false},
                       actor: actor(ctx),
                       execution_id: binding.execution_id
                     )

            assert Repo.get!(Message, persisted.assistant_message_id).content == "Thread answer"
            assert :ok = HistorySync.complete(session, persisted, result)
            result
          end)

        assert outgoing.metadata.error == false
        assert outgoing.body == "Thread answer"
        assert_receive {:model_input, body}, 5_000
        assert length(Regex.scan(~r/ROOT_HISTORY_CONTENT/, body)) == 1
        refute body =~ "INLINE_COPY"
        if attempt == 2, do: assert(body =~ "LATER_HISTORY_CONTENT")

        assert {:ok, [runtime]} = ServerManager.runtime_candidates(actor(ctx))
        assert runtime.agent.id == agent.id
        pid = runtime.runtime_pid

        assert {:ok, %{status: :completed}} =
                 AgentServer.await_completion(pid,
                   status_path: [:__strategy__, :status],
                   result_path: [:__strategy__, :result],
                   timeout: 5_000
                 )

        pid
      end

    assert length(Enum.uniq(runtimes)) == 1
    :ok = ServerManager.stop_server(agent)
  end

  defp incoming(ctx, id, target, content, room \\ "room@g.us") do
    quoted = if target, do: %{id: target, text: "INLINE_COPY", channel_jid: room}

    assert {:ok, native} =
             Adapter.transform_incoming(%{
               id: id,
               channel_jid: room,
               from_jid: "author@s.whatsapp.net",
               type: :text,
               text: content,
               quoted: quoted,
               pushname: ctx.person.full_name
             })

    native
    |> JidoChatBridge.to_internal(%{provider: :whatsapp, id: ctx.config.id})
    |> Map.put(:person, %{id: ctx.person.id, full_name: ctx.person.full_name})
    |> CommunicationBridge.put_conversation_identity()
  end

  defp project(ctx, id, target) do
    input = incoming(ctx, id, target, "Question")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    assert {:ok, projection} = Conversations.execution_history(binding, actor(ctx))
    {input, binding, projection}
  end

  defp connector,
    do: Zaq.WhatsAppFixtures.connector(%{name: "Thread #{Ecto.UUID.generate()}", enabled: true})

  defp add_identity(person, config) do
    assert {:ok, _} =
             People.add_channel(%{
               person_id: person.id,
               platform: "whatsapp",
               channel_identifier: "author@s.whatsapp.net",
               channel_config_id: config.id
             })
  end

  defp actor(ctx), do: %{person: %{id: ctx.person.id}}
  defp resource(ctx), do: ChannelHistoryResource.for("whatsapp", ctx.config.id, "room@g.us")

  defp grant(ctx),
    do: Permissions.grant(resource(ctx), %{person_id: ctx.person.id, access_rights: ["read"]})
end
