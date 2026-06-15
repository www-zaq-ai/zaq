defmodule Zaq.Engine.ConversationsTitleGenerationIntegrationTest do
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Engine.Conversations
  alias Zaq.TestSupport.OpenAIStub

  setup do
    original = Application.get_env(:zaq, :title_generation_enabled)
    Application.put_env(:zaq, :title_generation_enabled, true)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:zaq, :title_generation_enabled)
      else
        Application.put_env(:zaq, :title_generation_enabled, original)
      end
    end)

    :ok
  end

  test "broadcasts a generated title for the first user message" do
    handler = fn _conn, _body ->
      {200, OpenAIStub.chat_completion("Generated Support Title")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)
    OpenAIStub.seed_llm_config(endpoint)

    {:ok, conv} =
      Conversations.create_conversation(%{channel_type: "bo", channel_user_id: "title-success"})

    conv_id = conv.id

    Phoenix.PubSub.subscribe(Zaq.PubSub, "conversation:#{conv_id}")

    assert {:ok, _msg} = Conversations.add_message(conv, %{role: "user", content: "Need a title"})

    assert_receive {:openai_request, "POST", "/v1/chat/completions", "", _body}, 5_000
    assert_receive {:title_updated, ^conv_id, "Generated Support Title"}, 5_000

    assert Conversations.get_conversation!(conv_id).title == "Generated Support Title"
  end

  test "broadcasts a deterministic fallback title when generation fails" do
    handler = fn _conn, _body ->
      {503, %{"error" => %{"message" => "service unavailable"}}}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)
    OpenAIStub.seed_llm_config(endpoint)

    {:ok, conv} =
      Conversations.create_conversation(%{channel_type: "bo", channel_user_id: "title-error"})

    conv_id = conv.id

    Phoenix.PubSub.subscribe(Zaq.PubSub, "conversation:#{conv_id}")

    assert {:ok, _msg} = Conversations.add_message(conv, %{role: "user", content: "Need a title"})

    assert_receive {:openai_request, "POST", "/v1/chat/completions", "", _body}, 5_000

    # Provider errors must never leave a conversation untitled: TitleGenerator
    # derives a deterministic fallback from the user's own message and the
    # caller applies + broadcasts it like any other title.
    assert_receive {:title_updated, ^conv_id, "Need A Title"}, 5_000

    assert Conversations.get_conversation!(conv_id).title == "Need A Title"
  end

  test "does not broadcast a title if the conversation is deleted before the LLM responds" do
    test_pid = self()

    handler = fn _conn, _body ->
      send(test_pid, {:title_request_started, self()})

      receive do
        :release -> {200, OpenAIStub.chat_completion("Late title should be ignored")}
      end
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)
    OpenAIStub.seed_llm_config(endpoint)

    {:ok, conv} =
      Conversations.create_conversation(%{channel_type: "bo", channel_user_id: "title-deleted"})

    conv_id = conv.id

    Phoenix.PubSub.subscribe(Zaq.PubSub, "conversation:#{conv_id}")

    assert {:ok, _msg} = Conversations.add_message(conv, %{role: "user", content: "Need a title"})

    assert_receive {:openai_request, "POST", "/v1/chat/completions", "", _body}, 5_000
    assert_receive {:title_request_started, request_pid}, 5_000

    assert {:ok, _deleted} = Conversations.delete_conversation(conv)
    send(request_pid, :release)

    refute_receive {:title_updated, ^conv_id, _title}, 500
    assert is_nil(Conversations.get_conversation(conv_id))
  end
end
