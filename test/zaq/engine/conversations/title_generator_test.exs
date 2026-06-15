defmodule Zaq.Engine.Conversations.TitleGeneratorTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Conversations.TitleGenerator
  alias Zaq.TestSupport.OpenAIStub

  describe "generate/2 deterministic lane" do
    test "strips quotes and common title prefixes" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("\"Title: Admin Panel Password Reset Steps\"")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, "Admin Panel Password Reset Steps"} =
               TitleGenerator.generate("How do I reset my password in the admin panel?")
    end

    test "truncates generated titles to 6 words" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("One Two Three Four Five Six Seven Eight")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, "One Two Three Four Five Six"} =
               TitleGenerator.generate("Please summarize this long conversation")
    end

    test "uses model override payload and omits top_p" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        assert payload["model"] == "custom-model"
        refute Map.has_key?(payload, "top_p")

        {200, OpenAIStub.chat_completion("Custom Model Title")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint, model: "base-model")

      assert {:ok, "Custom Model Title"} =
               TitleGenerator.generate("How should model override work?", model: "custom-model")

      assert_receive {:openai_request, "POST", "/v1/chat/completions", "", _body}
    end

    test "falls back to a message-derived title when assistant content is unusable" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("   ")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:fallback, "Can You Help Me With Account", "Empty assistant response content"} =
               TitleGenerator.generate("Can you help me with account settings?")
    end

    test "falls back and surfaces the error when the LLM call fails" do
      handler = fn _conn, _body ->
        {503, %{"error" => %{"message" => "Service unavailable", "type" => "server_error"}}}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:fallback, "Please Generate A Title", reason} =
               TitleGenerator.generate("Please generate a title")

      refute is_nil(reason)
    end

    test "falls back to the default title when the user message is blank" do
      handler = fn _conn, _body ->
        {503, %{"error" => %{"message" => "Service unavailable", "type" => "server_error"}}}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:fallback, "New Conversation", _reason} = TitleGenerator.generate("   ")
    end
  end
end
