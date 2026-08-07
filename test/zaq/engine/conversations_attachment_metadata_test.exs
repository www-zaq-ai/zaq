defmodule Zaq.Engine.ConversationsAttachmentMetadataTest do
  # What a person attached is kept on the user message so the transcript can draw a file chip
  # without reading the trace or fetching bytes. The bytes are a trace concern and live in
  # `message_trace_artifacts`.
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Incoming

  defp incoming(content, records) do
    %Incoming{
      content: content,
      channel_id: "chan-attach",
      author_id: "author-attach",
      provider: :telegram,
      attachments: %RecordPage{resource_type: :attachment, records: records}
    }
  end

  defp record(attrs \\ %{}) do
    struct!(
      %Record{
        id: "telegram://file/abc",
        kind: :file,
        name: "photo.png",
        mime_type: "image/png",
        size: 113_000
      },
      attrs
    )
  end

  defp result do
    %{
      answer: "Looked at it.",
      confidence_score: 0.9,
      latency_ms: 12,
      prompt_tokens: 3,
      completion_tokens: 4,
      total_tokens: 7
    }
  end

  defp user_message(conversation_id) do
    %Zaq.Engine.Conversations.Conversation{id: conversation_id}
    |> Conversations.list_messages()
    |> Enum.find(&(&1.role == "user"))
  end

  defp persist(incoming) do
    incoming
    |> CommunicationBridge.put_conversation_identity()
    |> Conversations.persist_from_incoming(result())
  end

  test "the chip a transcript needs travels on the user message" do
    assert {:ok, %{conversation_id: id}} = persist(incoming("look at this", [record()]))

    assert %{"attachments" => [chip]} = user_message(id).metadata

    assert chip == %{
             "attachment_id" => "telegram://file/abc",
             "name" => "photo.png",
             "mime_type" => "image/png",
             "size" => 113_000
           }
  end

  test "every attachment gets its own chip, in order" do
    records = [record(%{id: "a", name: "one.png"}), record(%{id: "b", name: "two.pdf"})]

    assert {:ok, %{conversation_id: id}} = persist(incoming("two files", records))

    assert %{"attachments" => [%{"name" => "one.png"}, %{"name" => "two.pdf"}]} =
             user_message(id).metadata
  end

  test "the bytes never travel — only what a chip renders" do
    with_content = record(%{content: Base.encode64("PNGBYTES")})

    assert {:ok, %{conversation_id: id}} = persist(incoming("look", [with_content]))

    assert %{"attachments" => [chip]} = user_message(id).metadata
    refute Map.has_key?(chip, "content")
  end

  test "a message with nothing attached carries no attachments key" do
    assert {:ok, %{conversation_id: id}} = persist(incoming("just text", []))

    assert user_message(id).metadata == %{}
  end

  test "a caption-less attachment writes no user row, so it carries no chip" do
    assert {:ok, %{conversation_id: id}} = persist(incoming("", [record()]))

    assert user_message(id) == nil
  end
end
