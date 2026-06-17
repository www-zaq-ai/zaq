defmodule Zaq.Engine.Conversations.TitleGenerationFromConversationsTest do
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Engine.Conversations
  alias Zaq.TestSupport.OpenAIStub

  setup do
    previous = Application.get_env(:zaq, :title_generation_enabled)
    Application.put_env(:zaq, :title_generation_enabled, true)

    on_exit(fn ->
      Application.put_env(:zaq, :title_generation_enabled, previous)
    end)
  end

  test "generates and broadcasts a title for the first user message" do
    handler = fn _conn, _body ->
      {200, OpenAIStub.chat_completion("Revenue Forecast Review")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)
    OpenAIStub.seed_llm_config(endpoint)

    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        channel_user_id: "title-user-#{System.unique_integer([:positive])}"
      })

    Phoenix.PubSub.subscribe(Zaq.PubSub, "conversation:#{conv.id}")

    assert {:ok, _msg} =
             Conversations.add_message(conv, %{
               role: "user",
               content: "Can you review the revenue forecast for next quarter?"
             })

    assert_receive {:openai_request, "POST", "/v1/chat/completions", "", _body}
    assert_receive {:title_updated, conv_id, "Revenue Forecast Review"}
    assert conv_id == conv.id
    assert Conversations.get_conversation!(conv.id).title == "Revenue Forecast Review"
  end
end
