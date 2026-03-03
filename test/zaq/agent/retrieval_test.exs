defmodule Zaq.Agent.RetrievalTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{LLM, PromptTemplate, Retrieval}

  describe "ask/2" do
    setup do
      # Seed the retrieval prompt template
      {:ok, _template} =
        PromptTemplate.create(%{
          slug: "retrieval",
          name: "Retrieval Prompt",
          body:
            "You are a query rewriting assistant. Rewrite the user question into search queries. Respond in JSON.",
          description: "System prompt for the retrieval agent",
          active: true
        })

      :ok
    end

    test "returns {:ok, decoded_json} with a system prompt override" do
      # Uses a system prompt override so we don't depend on LLM for unit tests.
      # Integration tests with a real LLM can omit the override.
      opts = [
        system_prompt: "Respond with valid JSON: {\"queries\": [\"test\"]}"
      ]

      # This test requires a running LLM endpoint.
      # Skip in CI or when no LLM is configured.
      case LLM.endpoint() do
        nil ->
          :skipped

        "" ->
          :skipped

        _endpoint ->
          assert {:ok, result} = Retrieval.ask("What is Elixir?", opts)
          assert is_map(result)
      end
    end

    test "build_history handles empty list" do
      # Indirectly tested — passing empty history should not raise
      opts = [
        system_prompt: "Respond with JSON: {\"queries\": [\"test\"]}",
        history: []
      ]

      case LLM.endpoint() do
        nil ->
          :skipped

        "" ->
          :skipped

        _endpoint ->
          assert {:ok, _result} = Retrieval.ask("test", opts)
      end
    end
  end
end
