defmodule Zaq.Agent.MediaAttachmentIntegrationTest do
  use Zaq.DataCase, async: false

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolResult
  alias Zaq.Accounts
  alias Zaq.Agent.{MediaResultTransformer, StreamEvents}
  alias Zaq.Agent.Tools.ActionContract
  alias Zaq.Agent.Tools.DataSource.DownloadDocument
  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Contracts.Record
  alias Zaq.ConversationLifecycleFixtures
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Conversations.MessageTraceArtifact
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.NoopAgentStatus

  setup :verify_on_exit!

  defmodule NestedRecord do
    use Jido.Action,
      name: "nested_record",
      description: "Returns a materialized record",
      schema: [record: [type: :any]]

    def run(%{record: record}, _context), do: {:ok, %{record: record}}
  end

  defmodule NestedPayload do
    use Jido.Action, name: "nested_payload", schema: [payload: [type: :any, required: true]]
    def run(%{payload: payload}, _context), do: {:ok, payload}
  end

  test "mixed nested ToolResult artifacts are all externalized before metadata projection" do
    record = %{media_record("RECORD_BYTES") | raw: %{"content" => "RAW_BYTES"}}
    part = ContentPart.image("PART_BYTES", "image/png")
    payload = %ToolResult{output: %{record: record, __content_parts__: [part]}, content: [part]}
    result = nested_stream_result(payload)

    assert Enum.sort(Enum.map(result.trace_artifacts, & &1.content)) ==
             ["PART_BYTES", "RECORD_BYTES"]

    assert Enum.all?(result.trace_artifacts, & &1.optional)
    json = Jason.encode!(result.trace)
    refute json =~ "RECORD_BYTES"
    refute json =~ "PART_BYTES"
    refute json =~ "RAW_BYTES"

    for artifact <- result.trace_artifacts do
      metadata = Jason.encode!(artifact.record)
      refute metadata =~ "RECORD_BYTES"
      refute metadata =~ "PART_BYTES"
      refute metadata =~ "RAW_BYTES"
    end
  end

  test "blank nested artifact names and MIME types use valid defaults" do
    record = %{media_record("bytes") | name: "  ", mime_type: ""}
    result = nested_stream_result(%{record: record})
    assert [%{name: "attachment", mime_type: "application/octet-stream"}] = result.trace_artifacts
  end

  test "a rejected optional artifact does not discard a valid sibling artifact" do
    part = ContentPart.image("png", "image/png")
    payload = %ToolResult{output: %{record: media_record("TOO_LARGE"), __content_parts__: [part]}}
    result = nested_stream_result(payload)

    assert {:ok, %{assistant_message_id: id}} =
             ConversationLifecycleFixtures.complete_exchange(persisted_incoming(), result,
               artifact_max_bytes: 4
             )

    persisted = Repo.get!(Message, id)
    [child] = persisted.trace
    assert child["artifact_omissions"] == [%{"reason" => "trace_artifact_too_large"}]
    assert [descriptor] = child["artifacts"]
    artifact = Repo.get!(MessageTraceArtifact, descriptor["id"])
    assert artifact.content == "png"
    refute Jason.encode!(artifact.record) =~ "TOO_LARGE"
  end

  test "optional artifact rejection preserves the answer or failed execution and omission evidence" do
    result = nested_stream_result(%{record: media_record("RESOURCE_BYTES")})
    [artifact] = result.trace_artifacts

    for failed? <- [false, true],
        {candidate, reason} <- [
          {artifact, "trace_artifact_too_large"},
          {%{artifact | content: nil}, "invalid_trace_artifact"},
          {%{artifact | name: "  "}, "invalid_trace_artifact"},
          {%{artifact | record: "invalid"}, "invalid_trace_artifact"}
        ] do
      incoming = persisted_incoming()
      outcome = result |> Map.put(:trace_artifacts, [candidate]) |> Map.put(:error, failed?)
      max_bytes = if reason == "trace_artifact_too_large", do: 4, else: 1024

      assert {:ok, finalized} =
               ConversationLifecycleFixtures.complete_exchange(incoming, outcome,
                 artifact_max_bytes: max_bytes
               )

      id = finalized.assistant_message_id || finalized.user_message_id
      persisted = Repo.get!(Message, id)

      if failed?,
        do: assert(is_nil(finalized.assistant_message_id)),
        else: assert(persisted.content == "Done")

      [child] = Enum.filter(persisted.trace, &(&1["origin"] == "zaq_action"))
      assert child["artifact_omissions"] == [%{"reason" => reason}]
      assert child["outcome"] == "succeeded"
      assert is_nil(child["artifacts"])
      refute Jason.encode!(persisted.trace) =~ "RESOURCE_BYTES"
      assert Repo.aggregate(MessageTraceArtifact, :count) == 0
    end
  end

  test "required artifacts remain strict and optional evidence cannot bypass finalization identity" do
    result = nested_stream_result(%{record: media_record("RESOURCE_BYTES")})
    [artifact] = result.trace_artifacts
    strict = Map.put(result, :trace_artifacts, [Map.put(artifact, :optional, false)])

    assert {:error, :trace_artifact_too_large} =
             ConversationLifecycleFixtures.complete_exchange(persisted_incoming(), strict,
               artifact_max_bytes: 4
             )

    strict =
      Map.put(result, :trace_artifacts, [Map.merge(artifact, %{optional: false, content: nil})])

    assert {:error, :invalid_trace_artifact} =
             ConversationLifecycleFixtures.complete_exchange(persisted_incoming(), strict)

    assert {:error, :user_message_not_found} =
             Conversations.finalize_incoming(Ecto.UUID.generate(), "invalid", result,
               artifact_max_bytes: 4
             )
  end

  defp persisted_incoming do
    owner = user_fixture()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        user_id: owner.id,
        channel_type: "mattermost",
        channel_user_id: "nested-#{owner.id}"
      })

    %Incoming{
      content: "Inspect",
      provider: :mattermost,
      channel_id: "nested",
      author_id: to_string(owner.id),
      metadata: %{conversation_id: conversation.id}
    }
  end

  defp nested_stream_result(payload) do
    context = %{
      tool_call_id: "root",
      request_id: "request",
      run_id: "run",
      tool_event_sink: {:pid, self()}
    }

    assert {:ok, ^payload} = ActionContract.execute(NestedPayload, %{payload: payload}, context)
    assert_receive {:jido_ai_request_event, started}
    assert_receive {:jido_ai_request_event, completed}
    terminal = event(:request_completed, 30, %{result: "Done"}, %{id: "root", name: "parent"})

    assert {:ok, result} =
             StreamEvents.consume(
               [started, completed, terminal],
               %Incoming{content: "Inspect", channel_id: "nested", provider: :mattermost},
               status_module: NoopAgentStatus
             )

    result
  end

  test "nested default-route artifacts survive authorized persistence without leaking resource bytes or capabilities" do
    bytes = <<0, 4, 8, 16>>
    record = %{media_record(bytes) | materialization_handle: "PRIVATE_CAPABILITY"}

    ctx = %{
      tool_call_id: "root",
      request_id: "nested-media",
      run_id: "nested-media",
      tool_event_sink: {:pid, self()}
    }

    assert {:ok, %{record: ^record}} =
             ActionContract.execute(NestedRecord, %{record: record}, ctx)

    assert_receive {:jido_ai_request_event, started}
    assert_receive {:jido_ai_request_event, completed}
    root = %{id: "root", name: "parent"}

    events = [
      event(:tool_started, 10, %{}, root),
      started,
      completed,
      event(:tool_completed, 20, %{result: {:ok, %{value: 42}, []}}, root),
      event(:request_completed, 30, %{result: "Done"}, root)
    ]

    incoming = %Incoming{
      content: "Nested media",
      provider: :mattermost,
      channel_id: "nested-media"
    }

    assert {:ok, result} = StreamEvents.consume(events, incoming, status_module: NoopAgentStatus)
    assert [%{content: ^bytes}] = result.trace_artifacts
    refute inspect(result.trace) =~ "PRIVATE_CAPABILITY"
    refute inspect(result.trace) =~ inspect(bytes)
    owner = user_fixture()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        user_id: owner.id,
        channel_type: "mattermost",
        channel_user_id: "nested-#{owner.id}"
      })

    incoming = %{
      incoming
      | author_id: to_string(owner.id),
        metadata: %{conversation_id: conversation.id}
    }

    assert {:ok, %{assistant_message_id: id}} =
             ConversationLifecycleFixtures.complete_exchange(incoming, result)

    message = Repo.get!(Message, id)
    child = Enum.find(message.trace, &(&1["origin"] == "zaq_action"))
    assert child["invocation_path"] == completed.data.invocation_path
    assert [descriptor] = child["artifacts"]

    assert {:ok, artifact} =
             Conversations.get_authorized_trace_artifact(
               descriptor["id"],
               Accounts.get_user(owner.id)
             )

    assert artifact.content == bytes

    refute Jason.encode!(Repo.get!(MessageTraceArtifact, descriptor["id"]).record) =~
             "PRIVATE_CAPABILITY"
  end

  test "accessed lazy media flows from hydration through authorized trace persistence" do
    bytes = <<0, 1, 2, 3>>

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      case Keyword.fetch!(event.opts, :action) do
        :materialize_record ->
          %{event | response: {:ok, %{record: media_record(bytes)}}}
      end
    end)

    {:ok, handle} =
      CommunicationMedia.issue("mattermost", "media-integration", %{
        "name" => "diagram.png",
        "mime_type" => "image/png",
        "size" => byte_size(bytes),
        "media_kind" => "image",
        "source_author_id" => "author-1"
      })

    tool_call = %{id: "tool-media", name: "download_document", arguments: %{}}

    assert {:ok, %{record: %Record{content: ^bytes} = materialized_record}} =
             DownloadDocument.run(%{materialization_handle: handle}, %{
               node_router: Zaq.NodeRouterMock,
               actor: %{id: "author-1"}
             })

    canonical_result = {:ok, %{record: materialized_record}, []}

    assert {:ok, {:ok, %ToolResult{content: [%ContentPart{type: :image, data: ^bytes}]}, []}} =
             MediaResultTransformer.project_tool_result(
               tool_call,
               canonical_result,
               %{node_router: Zaq.NodeRouterMock}
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

    assert {:ok, %{assistant_message_id: message_id}} =
             Zaq.ConversationLifecycleFixtures.complete_exchange(
               persisted_incoming,
               stream_result
             )

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

  defp media_record(bytes) do
    %Record{
      id: "media-integration",
      kind: :file,
      content: bytes,
      name: "diagram.png",
      mime_type: "image/png",
      size: byte_size(bytes),
      attributes: %{
        "source_type" => "communication_media",
        "provider" => "mattermost",
        "source_id" => "media-integration",
        "media_kind" => "image"
      }
    }
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
