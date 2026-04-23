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
    test "returns error when LLM returns nil content" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion(nil)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = TitleGenerator.generate("How do I reset my password?")
      assert is_binary(message)
    end
  end

  describe "generate/2 — whitespace-only response after trimming" do
    test "returns error when content becomes empty after prefix removal" do
      handler = fn _conn, _body ->
        # A string that is only whitespace after trimming
        {200, OpenAIStub.chat_completion("   ")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, "Empty assistant response content"} =
               TitleGenerator.generate("Anything")
    end
  end
end
