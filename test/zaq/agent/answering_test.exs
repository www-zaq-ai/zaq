defmodule Zaq.Agent.AnsweringTest.FakeFactory do
  @moduledoc false

  def ask(_server, _query, _opts) do
    case Process.get(:fake_factory_response) do
      {:error, _} = err -> err
      _ -> {:ok, make_ref()}
    end
  end

  def await(_request, _opts), do: Process.get(:fake_factory_response)
end

defmodule Zaq.Agent.AnsweringTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Answering
  alias Zaq.Agent.Answering.Result
  alias Zaq.Agent.AnsweringTest.FakeFactory
  alias Zaq.Agent.PromptTemplate

  defp stub_factory(response) do
    Process.put(:fake_factory_response, response)
    [factory_module: FakeFactory]
  end

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

    test "normalizes string-keyed numeric payload values" do
      assert {:ok, %Result{} = result} =
               Answering.normalize_result(%{
                 "answer" => "ok",
                 "confidence" => %{"score" => 0.6},
                 "latency_ms" => 120.9,
                 "prompt_tokens" => 10.0,
                 "completion_tokens" => 5.0,
                 "total_tokens" => 15.0
               })

      assert result.answer == "ok"
      assert result.confidence_score == 0.6
      assert result.latency_ms == 120
      assert result.prompt_tokens == 10
      assert result.completion_tokens == 5
      assert result.total_tokens == 15
    end

    test "returns invalid result for unsupported payload" do
      assert {:error, :invalid_result} = Answering.normalize_result(%{foo: "bar"})
    end
  end

  describe "ask/2 with stubbed factory" do
    test "returns answer result when agent succeeds with binary result" do
      opts = stub_factory({:ok, "The BEAM VM."})

      assert {:ok, %Result{} = result} = Answering.ask("Context + question", opts)
      assert result.answer == "The BEAM VM."
      assert is_integer(result.latency_ms)
      assert is_nil(result.confidence_score)
      assert is_nil(result.clarification)
    end

    test "returns answer from %{result: text} handle shape" do
      opts = stub_factory({:ok, %{result: "Answer from result key."}})

      assert {:ok, %Result{answer: "Answer from result key."}} = Answering.ask("Prompt", opts)
    end

    test "returns answer from %{response: text} handle shape" do
      opts = stub_factory({:ok, %{response: "Answer from response key."}})

      assert {:ok, %Result{answer: "Answer from response key."}} = Answering.ask("Prompt", opts)
    end

    test "returns clarification result when agent signals clarification_needed" do
      clarification_result = %{
        clarification_needed: true,
        question: "Do you mean Product A or Product B?",
        reason: "Ambiguous product name"
      }

      opts = stub_factory({:ok, %{result: clarification_result}})

      assert {:ok, %Result{} = result} = Answering.ask("Prompt", opts)
      assert result.clarification == "Do you mean Product A or Product B?"
      assert result.answer == "Do you mean Product A or Product B?"
    end

    test "returns error tuple when agent returns error" do
      opts = stub_factory({:error, :model_unavailable})

      assert {:error, message} = Answering.ask("Prompt", opts)
      assert String.starts_with?(message, "Failed to formulate response:")
    end

    test "returns error when agent returns empty string" do
      opts = stub_factory({:ok, "   "})

      assert {:error, message} = Answering.ask("Prompt", opts)
      assert String.contains?(message, "Empty assistant response content")
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

  defp upsert_prompt_template(attrs) do
    case PromptTemplate.get_by_slug(attrs.slug) do
      nil -> PromptTemplate.create(attrs)
      template -> PromptTemplate.update(template, attrs)
    end
  end
end
