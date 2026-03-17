defmodule Zaq.Agent.AnsweringTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{Answering, LLM}
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

  setup do
    original = Application.get_env(:zaq, LLM)

    on_exit(fn ->
      if original do
        Application.put_env(:zaq, LLM, original)
      else
        Application.delete_env(:zaq, LLM)
      end
    end)

    :ok
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

  describe "ask/2 deterministic lane" do
    test "returns plain answer when confidence is explicitly disabled" do
      handler = fn _conn, body ->
        payload = Jason.decode!(body)
        refute Map.has_key?(payload, "logprobs")
        {200, OpenAIStub.chat_completion("The BEAM VM.")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      Application.put_env(:zaq, LLM, OpenAIStub.llm_config(endpoint, supports_logprobs: true))

      assert {:ok, "The BEAM VM."} =
               Answering.ask("Context + question", include_confidence: false)
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

      Application.put_env(:zaq, LLM, OpenAIStub.llm_config(endpoint, supports_logprobs: true))

      assert {:ok, %{answer: "The BEAM VM.", confidence: %{score: score}}} =
               Answering.ask("Context + question", include_confidence: true)

      assert is_float(score)
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

      Application.put_env(:zaq, LLM, OpenAIStub.llm_config(endpoint, supports_logprobs: true))

      assert {:ok, %{answer: "Default confidence path.", confidence: %{score: _score}}} =
               Answering.ask("Prompt")
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

      Application.put_env(:zaq, LLM, OpenAIStub.llm_config(endpoint, supports_logprobs: false))

      assert {:ok, "ok"} = Answering.ask("Prompt", history: history)
    end

    test "returns error tuple when confidence parsing fails" do
      handler = fn _conn, _body ->
        {200, OpenAIStub.chat_completion("No logprobs included")}
      end

      {child_spec, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child_spec)

      Application.put_env(:zaq, LLM, OpenAIStub.llm_config(endpoint, supports_logprobs: true))

      assert {:error, message} = Answering.ask("Prompt", include_confidence: true)
      assert String.starts_with?(message, "Failed to formulate response:")
    end
  end

  describe "ask/2 — full pipeline (requires running LLM)" do
    @describetag :integration
    test "returns answer with confidence when logprobs supported" do
      {:ok, result} =
        Answering.ask("Context: Elixir runs on the BEAM. Question: What does Elixir run on?",
          include_confidence: true
        )

      assert is_map(result)
      assert Map.has_key?(result, :answer)
      assert Map.has_key?(result, :confidence)
      assert is_float(result.confidence.score)
    end

    test "returns plain answer when confidence disabled" do
      {:ok, result} =
        Answering.ask("Context: Elixir runs on the BEAM. Question: What does Elixir run on?",
          include_confidence: false
        )

      assert is_binary(result)
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
