defmodule Zaq.Agent.RetrievalTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{PromptTemplate, Retrieval}
  alias Zaq.TestSupport.OpenAIStub

  describe "ask/2" do
    setup do
      # Seed/update the retrieval prompt template
      {:ok, _template} =
        upsert_prompt_template(%{
          slug: "retrieval",
          name: "Retrieval Prompt",
          body:
            "You are a query rewriting assistant. Rewrite the user question into search queries. Respond in JSON.",
          description: "System prompt for the retrieval agent",
          active: true
        })

      :ok
    end

    test "never sends response_format regardless of supports_json_mode config" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        refute Map.has_key?(payload, "response_format")
        {200, OpenAIStub.chat_completion(~s({"queries":["elixir beam"]}))}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint, supports_json_mode: true)

      assert {:ok, %{"queries" => ["elixir beam"]}} =
               Retrieval.ask("What does Elixir run on?", system_prompt: "Return JSON")
    end

    test "builds history from map for user and bot with non-binary bodies" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        messages = payload["messages"]

        assert Enum.any?(messages, fn msg ->
                 msg["role"] == "system" and message_text(msg) == "Prompt"
               end)

        assert Enum.any?(messages, fn msg ->
                 msg["role"] == "assistant" and
                   message_text(msg) == Jason.encode!(%{"step" => "done"})
               end)

        assert Enum.any?(messages, fn msg ->
                 msg["role"] == "user" and message_text(msg) == Jason.encode!(%{"q" => "hello"})
               end)

        assert Enum.any?(messages, fn msg ->
                 msg["role"] == "user" and message_text(msg) == "Latest question"
               end)

        {200, OpenAIStub.chat_completion(~s({"queries":["q"]}))}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      history = %{
        "1" => %{"body" => %{"step" => "done"}, "type" => "bot"},
        "2" => %{"body" => %{"q" => "hello"}, "type" => "user"}
      }

      assert {:ok, %{"queries" => ["q"]}} =
               Retrieval.ask("Latest question", system_prompt: "Prompt", history: history)
    end

    test "does not append a user message when question is empty" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        messages = payload["messages"]
        assert [%{"role" => "system"} = msg] = messages
        assert message_text(msg) == "Prompt"

        {200, OpenAIStub.chat_completion(~s({"queries":[]}))}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, %{"queries" => []}} = Retrieval.ask("", system_prompt: "Prompt")
    end

    test "returns error on invalid JSON content returned by the model" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("not-json")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert String.starts_with?(message, "Failed to process question:")
    end

    test "returns error when model response content is nil" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion(nil)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert String.contains?(message, "Failed to process question:")
      assert String.contains?(message, "Empty assistant response content")
    end

    @tag :integration
    test "returns {:ok, decoded_json} with a system prompt override" do
      # Uses a system prompt override so we don't depend on LLM for unit tests.
      # Integration tests with a real LLM can omit the override.
      opts = [
        system_prompt: "Respond with valid JSON: {\"queries\": [\"test\"]}"
      ]

      # This test requires a running LLM endpoint.
      # Skip in CI or when no LLM is configured.
      case Zaq.System.get_llm_config().endpoint do
        nil ->
          :skipped

        "" ->
          :skipped

        _endpoint ->
          assert {:ok, result} = Retrieval.ask("What is Elixir?", opts)
          assert is_map(result)
      end
    end

    @tag :integration
    test "build_history handles empty list" do
      # Indirectly tested — passing empty history should not raise
      opts = [
        system_prompt: "Respond with JSON: {\"queries\": [\"test\"]}",
        history: []
      ]

      case Zaq.System.get_llm_config().endpoint do
        nil ->
          :skipped

        "" ->
          :skipped

        _endpoint ->
          assert {:ok, _result} = Retrieval.ask("test", opts)
      end
    end
  end

  defp message_text(%{"content" => content}) when is_binary(content), do: content
  defp message_text(%{"content" => [%{"text" => text}]}), do: text

  defp upsert_prompt_template(attrs) do
    case PromptTemplate.get_by_slug(attrs.slug) do
      nil -> PromptTemplate.create(attrs)
      template -> PromptTemplate.update(template, attrs)
    end
  end
end
