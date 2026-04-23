defmodule Zaq.Agent.AnsweringCoverageTest.FakeFactory do
  @moduledoc false

  def ask(_server, _query, _opts) do
    case Process.get(:fake_factory_response) do
      {:error, _} = err -> err
      _ -> {:ok, make_ref()}
    end
  end

  def await(_request, _opts), do: Process.get(:fake_factory_response, {:ok, "stub answer"})
end

defmodule Zaq.Agent.AnsweringCoverageTest.FakeFactoryWithLogprobs do
  @moduledoc false

  def ask(_server, _query, _opts), do: {:ok, make_ref()}

  def await(_request, _opts) do
    logprob = Process.get(:stub_logprob, -0.05)

    :telemetry.execute([:req_llm, :openai, :logprobs], %{}, %{
      logprobs: [%{"logprob" => logprob}]
    })

    {:ok, "stub answer with logprobs"}
  end
end

defmodule Zaq.Agent.AnsweringCoverageTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Answering
  alias Zaq.Agent.Answering.Result
  alias Zaq.Agent.PromptTemplate

  alias Zaq.Agent.AnsweringCoverageTest.FakeFactory
  alias Zaq.Agent.AnsweringCoverageTest.FakeFactoryWithLogprobs

  defp stub_factory(response) do
    Process.put(:fake_factory_response, response)
    [factory_module: FakeFactory]
  end

  setup do
    {:ok, _template} =
      upsert_prompt_template(%{
        slug: "answering",
        name: "Answering Prompt",
        body: "You are a helpful assistant.",
        description: "System prompt for the answering agent",
        active: true
      })

    :ok
  end

  # ---------------------------------------------------------------------------
  # normalize_result — additional branches
  # ---------------------------------------------------------------------------

  describe "normalize_result/1 — additional branches" do
    test "passes through an already-built Result struct" do
      result = %Result{answer: "already built"}
      assert {:ok, ^result} = Answering.normalize_result(result)
    end

    test "extracts confidence as direct number from atom-keyed payload" do
      assert {:ok, %Result{confidence_score: 0.75}} =
               Answering.normalize_result(%{answer: "ok", confidence: 0.75})
    end

    test "extracts confidence as direct number from string-keyed payload" do
      assert {:ok, %Result{confidence_score: 0.5}} =
               Answering.normalize_result(%{"answer" => "ok", "confidence" => 0.5})
    end

    test "extracts confidence map with score key from string-keyed payload" do
      assert {:ok, %Result{confidence_score: 0.9}} =
               Answering.normalize_result(%{"answer" => "ok", "confidence" => %{"score" => 0.9}})
    end

    test "nil confidence when confidence field is missing" do
      assert {:ok, %Result{confidence_score: nil}} =
               Answering.normalize_result(%{answer: "ok"})
    end

    test "returns invalid_result for nil" do
      assert {:error, :invalid_result} = Answering.normalize_result(nil)
    end

    test "returns invalid_result for integer" do
      assert {:error, :invalid_result} = Answering.normalize_result(42)
    end
  end

  # ---------------------------------------------------------------------------
  # ask/2 with stubbed factory — additional paths
  # ---------------------------------------------------------------------------

  describe "ask/2 with stubbed factory — additional paths" do
    test "returns answer from top-level clarification_needed handle" do
      clarification_result = %{clarification_needed: true, question: "Which region?"}
      opts = stub_factory({:ok, clarification_result})

      assert {:ok, %Result{clarification: "Which region?"}} = Answering.ask("Prompt", opts)
    end

    test "returns error when both answer and clarification are nil" do
      opts = stub_factory({:ok, %{unknown_key: "value"}})

      assert {:error, message} = Answering.ask("Prompt", opts)
      assert String.contains?(message, "Empty assistant response content")
    end

    test "error containing 'logprob' string triggers logprobs unsupported path" do
      opts = stub_factory({:error, "model does not support logprobs"})

      assert {:error, message} = Answering.ask("Prompt", opts)
      assert String.starts_with?(message, "Failed to formulate response:")
    end

    test "error containing 'log_prob' string triggers logprobs unsupported path" do
      opts = stub_factory({:error, "log_prob not supported by this model"})

      assert {:error, message} = Answering.ask("Prompt", opts)
      assert String.starts_with?(message, "Failed to formulate response:")
    end

    test "telemetry_dimensions option is accepted without crash" do
      opts =
        stub_factory({:ok, "The answer"}) ++
          [telemetry_dimensions: %{server_id: "srv-1"}]

      assert {:ok, %Result{answer: "The answer"}} = Answering.ask("Prompt", opts)
    end

    test "person_id and team_ids are forwarded without crash" do
      opts =
        stub_factory({:ok, "answer"}) ++
          [person_id: 99, team_ids: [1, 2, 3]]

      assert {:ok, %Result{answer: "answer"}} = Answering.ask("Prompt", opts)
    end

    test "non-map telemetry_dimensions is normalised to empty map without crash" do
      opts =
        stub_factory({:ok, "The answer"}) ++
          [telemetry_dimensions: :not_a_map]

      assert {:ok, %Result{answer: "The answer"}} = Answering.ask("Prompt", opts)
    end
  end

  # ---------------------------------------------------------------------------
  # no_answer? — additional signals
  # ---------------------------------------------------------------------------

  describe "no_answer?/1 — additional no-answer signals" do
    test "detects 'i do not have'" do
      assert Answering.no_answer?("I do not have that information.")
    end

    test "detects 'not enough information'" do
      assert Answering.no_answer?("There is not enough information to answer.")
    end

    test "detects 'i can't answer'" do
      assert Answering.no_answer?("I can't answer that based on context.")
    end

    test "detects 'outside my knowledge'" do
      assert Answering.no_answer?("That is outside my knowledge.")
    end

    test "detects 'no relevant'" do
      assert Answering.no_answer?("No relevant documents were found.")
    end
  end

  # ---------------------------------------------------------------------------
  # clean_answer — edge cases
  # ---------------------------------------------------------------------------

  describe "clean_answer/1 — edge cases" do
    test "returns empty string unchanged" do
      assert Answering.clean_answer("") == ""
    end

    test "removes opening code fence with language tag" do
      assert Answering.clean_answer("```elixir\ndefmodule Foo do\nend\n```") ==
               "defmodule Foo do\nend"
    end

    test "passes through non-string map as-is" do
      assert Answering.clean_answer(%{key: "value"}) == %{key: "value"}
    end

    test "passes through list as-is" do
      assert Answering.clean_answer([1, 2, 3]) == [1, 2, 3]
    end
  end

  # ---------------------------------------------------------------------------
  # Confidence scoring via logprobs (covers emit_answer_telemetry branches
  # and all confidence_bucket_metric clauses)
  # ---------------------------------------------------------------------------

  describe "confidence scoring via FakeFactoryWithLogprobs" do
    setup do
      on_exit(fn -> Process.delete(:stub_logprob) end)
      :ok
    end

    test "records confidence telemetry when logprobs yield score > 0.9 (gt_90 bucket)" do
      Process.put(:stub_logprob, -0.05)

      opts = [factory_module: FakeFactoryWithLogprobs]

      assert {:ok, %Result{confidence_score: score}} = Answering.ask("Prompt", opts)
      assert is_float(score)
      assert score > 0.9
    end

    test "confidence bucket between_80_90 (score > 0.8 and <= 0.9)" do
      Process.put(:stub_logprob, -0.18)

      opts = [factory_module: FakeFactoryWithLogprobs]

      assert {:ok, %Result{confidence_score: score}} = Answering.ask("Prompt", opts)
      assert is_float(score)
      assert score > 0.8 and score <= 0.9
    end

    test "confidence bucket between_70_80 (score > 0.7 and <= 0.8)" do
      Process.put(:stub_logprob, -0.28)

      opts = [factory_module: FakeFactoryWithLogprobs]

      assert {:ok, %Result{confidence_score: score}} = Answering.ask("Prompt", opts)
      assert is_float(score)
      assert score > 0.7 and score <= 0.8
    end

    test "confidence bucket between_50_70 (score >= 0.5 and <= 0.7)" do
      Process.put(:stub_logprob, -0.6)

      opts = [factory_module: FakeFactoryWithLogprobs]

      assert {:ok, %Result{confidence_score: score}} = Answering.ask("Prompt", opts)
      assert is_float(score)
      assert score >= 0.5 and score <= 0.7
    end

    test "confidence bucket lt_50 (score < 0.5)" do
      Process.put(:stub_logprob, -1.5)

      opts = [factory_module: FakeFactoryWithLogprobs]

      assert {:ok, %Result{confidence_score: score}} = Answering.ask("Prompt", opts)
      assert is_float(score)
      assert score < 0.5
    end
  end

  defp upsert_prompt_template(attrs) do
    case PromptTemplate.get_by_slug(attrs.slug) do
      nil -> PromptTemplate.create(attrs)
      template -> PromptTemplate.update(template, attrs)
    end
  end
end
