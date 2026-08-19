defmodule Zaq.Agent.MediaAttachmentIntegrationTest do
  use Zaq.DataCase, async: false

  alias ReqLLM.Message.ContentPart
  alias Zaq.Accounts
  alias Zaq.Agent.{MediaResultTransformer, StreamEvents}
  alias Zaq.Agent.Tools.DataSource.DownloadDocument
  alias Zaq.Contracts.{Record, RecordCapability}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.TestSupport.NoopAgentStatus

  setup :verify_on_exit!

  test "accessed lazy media flows from hydration through authorized trace persistence" do
    bytes = <<0, 1, 2, 3>>

    expect(Zaq.NodeRouterMock, :dispatch, 2, fn event ->
      case Keyword.fetch!(event.opts, :action) do
        :hydrate_record ->
          materializing_event =
            Event.new(%{record: event.request}, :channels, opts: [action: :materialize_record])

          %{event | response: {:ok, materializing_event}}

        :materialize_record ->
          %{event | response: {:ok, %{content: bytes}}}
      end
    end)

    record =
      %Record{
        id: "media-integration",
        kind: :file,
        name: "diagram.png",
        mime_type: "image/png",
        size: byte_size(bytes),
        attributes: %{
          "source_type" => "communication_media",
          "provider" => "mattermost",
          "source_id" => "media-integration",
          "source_author_id" => "author-1"
        }
      }
      |> RecordCapability.sign!()

    tool_call = %{id: "tool-media", name: "download_document", arguments: %{}}

    assert {:ok, %{record: %Record{content: ^bytes} = materialized_record}} =
             DownloadDocument.run(%{record: Record.metadata(record)}, %{
               node_router: Zaq.NodeRouterMock,
               actor: %{id: "author-1"}
             })

    canonical_result = {:ok, %{record: materialized_record}, []}

    assert {:ok, [%ContentPart{type: :image, data: ^bytes}]} =
             MediaResultTransformer.transform_tool_result(
               tool_call,
               "default",
               %{
                 tool_result: canonical_result,
                 runtime_context: %{node_router: Zaq.NodeRouterMock}
               }
             )

    events = [
      event(:tool_started, 10, %{tool_name: tool_call.name, arguments: %{}}, tool_call),
      event(
        :tool_completed,
        20,
        %{tool_name: tool_call.name, result: canonical_result},
        tool_call
      ),
      event(:request_completed, 30, %{result: "It is a diagram."}, tool_call)
    ]

    incoming = %Incoming{content: "Describe this", channel_id: "channel-1", provider: :mattermost}

    assert {:ok, stream_result} =
             StreamEvents.consume(events, incoming, status_module: NoopAgentStatus)

    assert canonical_result == {:ok, %{record: materialized_record}, []}
    assert [%{content: ^bytes}] = stream_result.trace_artifacts
    refute inspect(stream_result.trace) =~ inspect(bytes)

    owner = user_fixture()
    {:ok, owner} = Accounts.change_password(owner, %{password: "StrongPass1!"})

    {:ok, conversation} =
      Conversations.create_conversation(%{
        channel_type: "mattermost",
        channel_user_id: "owner-#{owner.id}",
        user_id: owner.id
      })

    persisted_incoming = %{
      incoming
      | author_id: to_string(owner.id),
        metadata: %{conversation_id: conversation.id}
    }

    result = Map.merge(stream_result, %{answer: stream_result.answer})

    assert {:ok, %{assistant_message_id: message_id}} =
             Conversations.persist_from_incoming(persisted_incoming, result)

    message = Repo.get!(Zaq.Engine.Conversations.Message, message_id)
    assert [%{"id" => "tool-media", "artifacts" => [descriptor]}] = message.trace

    assert {:ok, artifact} =
             Conversations.get_authorized_trace_artifact(
               descriptor["id"],
               Accounts.get_user(owner.id)
             )

    assert artifact.content == bytes
    assert artifact.mime_type == "image/png"
  end

  defp event(kind, at_ms, data, tool_call) do
    %{
      kind: kind,
      at_ms: at_ms,
      iteration: 1,
      tool_call_id: tool_call.id,
      tool_name: tool_call.name,
      data: data
    }
  end
end
