defmodule Zaq.Engine.Conversations.TitleGeneratorCoverageTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Conversations.TitleGenerator
  alias Zaq.TestSupport.OpenAIStub

  describe "generate/2 — prefix removal variants" do
    test "removes 'Here is' prefix" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("Here is Password Reset Steps")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, "Password Reset Steps"} =
               TitleGenerator.generate("How do I reset my password?")
    end

    test "removes 'Here's' prefix" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("Here's Sales Report Analysis")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, "Sales Report Analysis"} =
               TitleGenerator.generate("Can you summarize the Q4 sales report?")
    end

    test "removes 'The title is:' prefix" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("The title is: Employee Onboarding Checklist")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, "Employee Onboarding Checklist"} =
               TitleGenerator.generate("How do I onboard new employees?")
    end

    test "removes 'Title:' prefix with no surrounding quotes" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("Title: Admin Panel Password")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, "Admin Panel Password"} =
               TitleGenerator.generate("How do I get into the admin panel?")
    end
  end

  describe "generate/2 — nil response content" do
    test "falls back to a message-derived title when LLM returns nil content" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion(nil)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:fallback, "How Do I Reset My Password?", "Empty assistant response content"} =
               TitleGenerator.generate("How do I reset my password?")
    end

    test "falls back when the assistant message omits content" do
      handler = fn _conn, _body ->
        {200,
         %{
           "id" => "chatcmpl-test",
           "object" => "chat.completion",
           "created" => 0,
           "model" => "test-model",
           "choices" => [
             %{
               "index" => 0,
               "message" => %{"role" => "assistant"},
               "finish_reason" => "stop"
             }
           ]
         }}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:fallback, "How Do I Reset My Password?", "Empty assistant response content"} =
               TitleGenerator.generate("How do I reset my password?")
    end
  end

  describe "generate/2 — model and provider fallback coverage" do
    test "uses the provided model override" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        assert payload["model"] == "coverage-model"

        {200, OpenAIStub.chat_completion("Coverage Model Title")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint, model: "base-model")

      assert {:ok, "Coverage Model Title"} =
               TitleGenerator.generate("Which model handles this?", model: "coverage-model")
    end

    test "falls back when the provider returns an error tuple" do
      handler = fn _conn, _body ->
        {503, %{"error" => %{"message" => "service unavailable"}}}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:fallback, "Need A Coverage Title", reason} =
               TitleGenerator.generate("Need a coverage title")

      refute is_nil(reason)
    end

    test "falls back to the default title when the user message is blank" do
      handler = fn _conn, _body ->
        {503, %{"error" => %{"message" => "service unavailable"}}}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:fallback, "New Conversation", _reason} = TitleGenerator.generate("   ")
    end
  end

  describe "generate/2 — exception fallback" do
    test "rescues unexpected local errors and returns a deterministic fallback title" do
      assert {:fallback, "Explain Billing Retry Behavior", reason} =
               TitleGenerator.generate("Explain billing retry behavior", :invalid_opts)

      refute is_nil(reason)
    end
  end

  describe "generate/2 — whitespace-only response after trimming" do
    test "falls back when content becomes empty after prefix removal" do
      handler = fn _conn, _body ->
        # A string that is only whitespace after trimming
        {200, OpenAIStub.chat_completion("   ")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:fallback, "Anything", "Empty assistant response content"} =
               TitleGenerator.generate("Anything")
    end
  end
end
