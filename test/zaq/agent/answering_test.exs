defmodule Zaq.Agent.AnsweringTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Answering
  alias Zaq.Agent.Answering.Result
  alias Zaq.Agent.PromptTemplate
  alias Zaq.TestSupport.OpenAIStub

  setup do
    {:ok, template} =
      upsert_prompt_template(%{
        slug: "answering",
        name: "Answering Prompt",
        body: "You are a helpful assistant. Answer based on the provided context only.",
        description: "System prompt for the answering agent",
        active: true
      })

    %{template: template}
  end

  describe "no_answer?/1" do
    test "returns true for no-information answers" do
      assert Answering.no_answer?("I don't have enough information to answer that.")
      assert Answering.no_answer?("There is no information available on this topic.")
      assert Answering.no_answer?("I cannot answer this question based on the context.")
      assert Answering.no_answer?("No relevant data was found.")
      assert Answering.no_answer?("This is outside my knowledge base.")
    end

    test "returns false for actual answers" do
      refute Answering.no_answer?("The vacation policy allows 20 days per year.")
      refute Answering.no_answer?("Elixir is a functional programming language.")
    end

    test "is case-insensitive" do
      assert Answering.no_answer?("I DON'T HAVE the information you need.")
    end

    test "returns false for non-binary input" do
      refute Answering.no_answer?(nil)
      refute Answering.no_answer?(123)
    end
  end

  describe "clean_answer/1" do
    test "trims whitespace" do
      assert Answering.clean_answer("  hello  ") == "hello"
    end

    test "removes surrounding quotes" do
      assert Answering.clean_answer("\"hello world\"") == "hello world"
    end

    test "removes markdown code fences" do
      assert Answering.clean_answer("```\nhello\n```") == "hello"
      assert Answering.clean_answer("```json\n{\"a\": 1}\n```") == "{\"a\": 1}"
    end

    test "passes through non-binary input" do
      assert Answering.clean_answer(nil) == nil
      assert Answering.clean_answer(123) == 123
    end
  end

  describe "normalize_result/1" do
    test "normalizes legacy map result" do
      assert {:ok, %Result{} = result} =
               Answering.normalize_result(%{
                 answer: "ok",
                 confidence: %{score: 0.8},
                 latency_ms: 120,
                 prompt_tokens: 10,
                 completion_tokens: 5,
                 total_tokens: 15
               })

      assert result.answer == "ok"
      assert result.confidence_score == 0.8
      assert result.latency_ms == 120
      assert result.prompt_tokens == 10
      assert result.completion_tokens == 5
      assert result.total_tokens == 15
    end

    test "normalizes plain string result" do
      assert {:ok, %Result{answer: "ok"}} = Answering.normalize_result("ok")
    end
  end

  describe "ask/2 deterministic lane" do
    test "returns plain answer when confidence is explicitly disabled" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        refute Map.has_key?(payload, "logprobs")
        {200, OpenAIStub.chat_completion("The BEAM VM.")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint, supports_logprobs: true)

      assert {:ok, %Result{} = result} =
               Answering.ask("Context + question", include_confidence: false)

      assert result.answer == "The BEAM VM."
      assert is_integer(result.latency_ms)
      assert is_integer(result.prompt_tokens)
      assert is_integer(result.completion_tokens)
      assert is_integer(result.total_tokens)
      assert is_nil(result.confidence_score)
    end

    test "returns answer with confidence when confidence is enabled" do
      logprobs = %{"content" => [%{"token" => "BEAM", "logprob" => -0.1}]}

      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        assert payload["logprobs"] == true
        {200, OpenAIStub.chat_completion("The BEAM VM.", logprobs: logprobs)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint, supports_logprobs: true)

      assert {:ok, %Result{} = result} =
               Answering.ask("Context + question", include_confidence: true)

      assert result.answer == "The BEAM VM."
      score = result.confidence_score
      assert is_float(score)
      assert is_integer(result.latency_ms)
      assert is_integer(result.prompt_tokens)
      assert is_integer(result.completion_tokens)
      assert is_integer(result.total_tokens)
    end

    test "uses supports_logprobs default when include_confidence is omitted" do
      logprobs = %{"content" => [%{"token" => "x", "logprob" => -0.2}]}

      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        assert payload["logprobs"] == true
        {200, OpenAIStub.chat_completion("Default confidence path.", logprobs: logprobs)}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint, supports_logprobs: true)

      assert {:ok, %Result{} = result} = Answering.ask("Prompt")
      assert result.answer == "Default confidence path."
      assert is_float(result.confidence_score)
    end

    test "builds history from map including non-binary bodies" do
      history = %{
        "1" => %{"body" => %{"hello" => "world"}, "type" => "user"},
        "2" => %{"body" => [%{"a" => 1}], "type" => "bot"}
      }

      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        messages = payload["messages"]

        assert Enum.any?(messages, fn msg ->
                 msg["role"] == "system" and message_text(msg) == "Prompt"
               end)

        assert Enum.any?(messages, fn msg ->
                 msg["role"] == "user" and
                   message_text(msg) == Jason.encode!(%{"hello" => "world"})
               end)

        assert Enum.any?(messages, fn msg ->
                 msg["role"] == "assistant" and
                   message_text(msg) == Jason.encode!([%{"a" => 1}])
               end)

        {200, OpenAIStub.chat_completion("ok")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint, supports_logprobs: false)

      assert {:ok, %Result{} = result} = Answering.ask("Prompt", history: history)
      assert result.answer == "ok"
    end

    test "gracefully degrades when confidence parsing fails" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("No logprobs included")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      OpenAIStub.seed_llm_config(endpoint, supports_logprobs: true)

      assert {:ok, %Result{} = result} = Answering.ask("Prompt", include_confidence: true)
      assert result.answer == "No logprobs included"
      assert is_nil(result.confidence_score)
    end
  end

  describe "ask/2 — full pipeline (requires running LLM)" do
    @describetag :integration
    test "returns answer with confidence when logprobs supported" do
      {:ok, result} =
        Answering.ask("Context: Elixir runs on the BEAM. Question: What does Elixir run on?",
          include_confidence: true
        )

      assert %Result{} = result
      assert is_binary(result.answer)
      assert is_float(result.confidence_score)
    end

    test "returns plain answer when confidence disabled" do
      {:ok, result} =
        Answering.ask("Context: Elixir runs on the BEAM. Question: What does Elixir run on?",
          include_confidence: false
        )

      assert %Result{} = result
      assert is_binary(result.answer)
    end

    test "handles conversation history" do
      history = %{
        "1" => %{"body" => "What is Elixir?", "type" => "user"},
        "2" => %{"body" => "Elixir is a functional language.", "type" => "bot"}
      }

      {:ok, _result} =
        Answering.ask("Context: Elixir uses the BEAM VM. Question: Tell me more.",
          history: history,
          include_confidence: false
        )
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
