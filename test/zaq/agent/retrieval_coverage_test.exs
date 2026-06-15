defmodule Zaq.Agent.RetrievalCoverageTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{PromptTemplate, Retrieval}
  alias Zaq.SystemConfigFixtures
  alias Zaq.TestSupport.OpenAIStub

  setup do
    {:ok, _template} =
      upsert_prompt_template(%{
        slug: "retrieval",
        name: "Retrieval Prompt",
        body: "You are a query rewriting assistant. Reply in markdown format.",
        description: "System prompt for the retrieval agent",
        active: true
      })

    :ok
  end

  describe "ask/2 — markdown field parsing" do
    test "parses all four markdown fields from LLM response" do
      handler = fn _conn, _body ->
        {200,
         OpenAIStub.chat_completion("""
         **Query:** elixir beam scheduler
         **Language:** eng
         **Positive Answer:** Please wait while I search.
         **Negative Answer:** No information found, try rephrasing.
         """)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, result} = Retrieval.ask("What is Elixir?", system_prompt: "Prompt")
      assert result["query"] == "elixir beam scheduler"
      assert result["language"] == "eng"
      assert result["positive_answer"] == "Please wait while I search."
      assert result["negative_answer"] == "No information found, try rephrasing."
    end

    test "strips trailing prose from language field" do
      handler = fn _conn, _body ->
        {200,
         OpenAIStub.chat_completion("""
         **Query:** some query
         **Language:** und (undetermined, see note)
         **Positive Answer:** Searching...
         **Negative Answer:** Not found.
         """)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, result} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert result["language"] == "und"
    end

    test "defaults language to eng when field is missing" do
      handler = fn _conn, _body ->
        {200,
         OpenAIStub.chat_completion("""
         **Query:** some query
         **Positive Answer:** Searching...
         **Negative Answer:** Not found.
         """)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, result} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert result["language"] == "eng"
    end

    test "falls back to original question when query field is missing" do
      handler = fn _conn, _body ->
        {200,
         OpenAIStub.chat_completion("""
         **Language:** fra
         **Positive Answer:** Searching...
         **Negative Answer:** Not found.
         """)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, result} = Retrieval.ask("Original question", system_prompt: "Prompt")
      assert result["query"] == "Original question"
      assert result["language"] == "fra"
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

    test "returns error when LLM returns nil content" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion(nil)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)
      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert String.contains?(message, "Empty assistant response content")
    end
  end

  describe "ask/2 — network exception rescue" do
    test "returns error tuple when LLM connection raises an exception" do
      OpenAIStub.seed_llm_config("http://localhost:1")

      assert {:error, reason} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert is_struct(reason)
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

      assert {:error, reason} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert is_struct(reason)
    end
  end

  describe "ask/2 — Generation.generate_text raises exception" do
    test "returns error tuple when prepare_request raises (e.g., missing API key for anthropic)" do
      SystemConfigFixtures.seed_llm_config(%{
        provider: "anthropic",
        endpoint: "https://api.anthropic.com",
        api_key: ""
      })

      assert {:error, reason} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert is_struct(reason)
    end
  end

  defp upsert_prompt_template(attrs) do
    case PromptTemplate.get_by_slug(attrs.slug) do
      nil -> PromptTemplate.create(attrs)
      template -> PromptTemplate.update(template, attrs)
    end
  end
end
