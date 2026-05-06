defmodule Zaq.Agent.RetrievalCoverageTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{PromptTemplate, Retrieval}
  alias Zaq.TestSupport.OpenAIStub

  setup do
    {:ok, _template} =
      upsert_prompt_template(%{
        slug: "retrieval",
        name: "Retrieval Prompt",
        body: "You are a query rewriting assistant. Respond in JSON.",
        description: "System prompt for the retrieval agent",
        active: true
      })

    :ok
  end

  describe "ask/2 — extract_json with markdown code fences" do
    test "decodes JSON wrapped in ```json ... ``` code fence" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion(~s(```json\n{"queries":["elixir beam"]}\n```))}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, %{"queries" => ["elixir beam"]}} =
               Retrieval.ask("What does Elixir run on?", system_prompt: "Prompt")
    end

    test "decodes JSON wrapped in plain ``` code fence" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion(~s(```\n{"queries":["test query"]}\n```))}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, %{"queries" => ["test query"]}} =
               Retrieval.ask("Some question?", system_prompt: "Prompt")
    end
  end

  describe "ask/2 — whitespace response" do
    test "returns error when LLM returns only whitespace" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("   ")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert String.contains?(message, "Empty assistant response content")
    end
  end

  describe "ask/2 — exception rescue path" do
    test "returns error tuple when LLM raises an exception" do
      handler = fn _conn, _body ->
        {503, %{"error" => %{"message" => "Service unavailable", "type" => "server_error"}}}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert String.starts_with?(message, "Failed to process question:")
    end
  end

  defp upsert_prompt_template(attrs) do
    case PromptTemplate.get_by_slug(attrs.slug) do
      nil -> PromptTemplate.create(attrs)
      template -> PromptTemplate.update(template, attrs)
    end
  end
end
