defmodule Zaq.Agent.RetrievalTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{PromptTemplate, Retrieval}
  alias Zaq.TestSupport.OpenAIStub

  describe "ask/2" do
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

    test "never sends response_format regardless of supports_json_mode config" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        refute Map.has_key?(payload, "response_format")

        {200,
         OpenAIStub.chat_completion("""
         **Query:** elixir beam
         **Language:** eng
         **Positive Answer:** Please wait.
         **Negative Answer:** No info found.
         """)}
      end

      {_pid, endpoint} = OpenAIStub.start_server(handler, self())

      OpenAIStub.seed_llm_config(endpoint, supports_json_mode: true)

      assert {:ok, %{"query" => "elixir beam", "language" => "eng"}} =
               Retrieval.ask("What does Elixir run on?", system_prompt: "Return markdown")
    end

    test "builds history from map for user and bot with non-binary bodies" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        messages = payload["messages"]

        assert Enum.any?(messages, fn msg -> msg["role"] == "system" end)

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

        {200,
         OpenAIStub.chat_completion("""
         **Query:** hello query
         **Language:** eng
         **Positive Answer:** Searching now.
         **Negative Answer:** Nothing found.
         """)}
      end

      {_pid, endpoint} = OpenAIStub.start_server(handler, self())

      OpenAIStub.seed_llm_config(endpoint)

      history = %{
        "1" => %{"body" => %{"step" => "done"}, "type" => "bot"},
        "2" => %{"body" => %{"q" => "hello"}, "type" => "user"}
      }

      assert {:ok, %{"query" => "hello query"}} =
               Retrieval.ask("Latest question", system_prompt: "Prompt", history: history)
    end

    test "does not append a user message when question is empty" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        messages = payload["messages"]
        assert [%{"role" => "system"}] = messages

        {200,
         OpenAIStub.chat_completion("""
         **Query:** fallback
         **Language:** eng
         **Positive Answer:** Searching.
         **Negative Answer:** Not found.
         """)}
      end

      {_pid, endpoint} = OpenAIStub.start_server(handler, self())

      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, %{"query" => "fallback"}} = Retrieval.ask("", system_prompt: "Prompt")
    end

    test "falls back to raw question when model returns no markdown fields" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("not a markdown response")}
      end

      {_pid, endpoint} = OpenAIStub.start_server(handler, self())

      OpenAIStub.seed_llm_config(endpoint)

      assert {:ok, result} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert result["query"] == "Question"
      assert result["language"] == "eng"
    end

    test "returns error when model response content is nil" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion(nil)}
      end

      {_pid, endpoint} = OpenAIStub.start_server(handler, self())

      OpenAIStub.seed_llm_config(endpoint)

      assert {:error, message} = Retrieval.ask("Question", system_prompt: "Prompt")
      assert String.contains?(message, "Failed to process question:")
      assert String.contains?(message, "Empty assistant response content")
    end

    @tag :integration
    test "returns {:ok, result} with a system prompt override" do
      opts = [
        system_prompt:
          "Reply in this exact format:\n**Query:** test\n**Language:** eng\n**Positive Answer:** ok\n**Negative Answer:** none"
      ]

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
      opts = [
        system_prompt:
          "Reply in this exact format:\n**Query:** test\n**Language:** eng\n**Positive Answer:** ok\n**Negative Answer:** none",
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
