defmodule Zaq.Agent.AnsweringCoverageTest.StubAgent do
  @moduledoc false
  use Jido.AI.Agent,
    name: "stub_answering_agent_coverage",
    description: "Stub agent for coverage tests",
    tools: []

  def ask_sync(_pid, _query, _opts), do: {:ok, "stub answer"}
end

defmodule Zaq.Agent.AnsweringCoverageTest.StubAgentWithLogprobs do
  @moduledoc false
  use Jido.AI.Agent,
    name: "stub_answering_agent_logprobs",
    description: "Stub agent that emits logprobs for coverage tests",
    tools: []

  def ask_sync(_pid, _query, _opts) do
    logprob = Process.get(:stub_logprob, -0.05)

    :telemetry.execute([:req_llm, :openai, :logprobs], %{}, %{logprobs: [%{"logprob" => logprob}]})

    {:ok, "stub answer with logprobs"}
  end
end

defmodule Zaq.Agent.AnsweringCoverageTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Answering
  alias Zaq.Agent.Answering.Result
  alias Zaq.Agent.PromptTemplate

  alias Zaq.Agent.AnsweringCoverageTest.StubAgent
  alias Zaq.Agent.AnsweringCoverageTest.StubAgentWithLogprobs

  defp run_fn_returning(response), do: fn _prompt, _msgs, _opts -> response end

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
  # ask/2 with run_fn — uncovered paths
  # ---------------------------------------------------------------------------

  describe "ask/2 with run_fn — additional paths" do
    test "returns answer from top-level clarification_needed handle" do
      clarification_result = %{clarification_needed: true, question: "Which region?"}
      opts = [run_fn: run_fn_returning({:ok, clarification_result})]

      assert {:ok, %Result{clarification: "Which region?"}} = Answering.ask("Prompt", opts)
    end

    test "returns error when both answer and clarification are nil" do
      opts = [run_fn: run_fn_returning({:ok, %{unknown_key: "value"}})]

      assert {:error, message} = Answering.ask("Prompt", opts)
      assert String.contains?(message, "Empty assistant response content")
    end

    test "error containing 'logprob' string triggers logprobs unsupported path" do
      opts = [run_fn: run_fn_returning({:error, "model does not support logprobs"})]

      assert {:error, message} = Answering.ask("Prompt", opts)
      assert String.starts_with?(message, "Failed to formulate response:")
    end

    test "error containing 'log_prob' string triggers logprobs unsupported path" do
      opts = [run_fn: run_fn_returning({:error, "log_prob not supported by this model"})]

      assert {:error, message} = Answering.ask("Prompt", opts)
      assert String.starts_with?(message, "Failed to formulate response:")
    end

    test "appends question as user message and still returns result" do
      test_pid = self()

      run_fn = fn _prompt, messages, _opts ->
        send(test_pid, {:messages, messages})
        {:ok, "answer"}
      end

      opts = [run_fn: run_fn, question: "What is Elixir?"]
      assert {:ok, %Result{answer: "answer"}} = Answering.ask("Prompt", opts)
      assert_receive {:messages, messages}
      # messages is a list of ReqLLM.Message structs when run_fn is used
      assert is_list(messages)
      assert length(messages) == 1
    end

    test "telemetry_dimensions option is accepted without crash" do
      opts = [
        run_fn: run_fn_returning({:ok, "The answer"}),
        telemetry_dimensions: %{server_id: "srv-1"}
      ]

      assert {:ok, %Result{answer: "The answer"}} = Answering.ask("Prompt", opts)
    end

    test "person_id and team_ids are forwarded without crash" do
      opts = [
        run_fn: run_fn_returning({:ok, "answer"}),
        person_id: 99,
        team_ids: [1, 2, 3]
      ]

      assert {:ok, %Result{answer: "answer"}} = Answering.ask("Prompt", opts)
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
  # Non-run_fn path — exercises set_system_prompt, format_messages,
  # content_to_string, capture_logprobs, release_logprobs, drain_logprobs
  # ---------------------------------------------------------------------------

  describe "ask/2 via real AgentServer (non-run_fn path)" do
    test "succeeds when set_prompt_fn returns {:ok, value}" do
      opts = [
        agent_mod: StubAgent,
        set_prompt_fn: fn _server, _prompt -> {:ok, :done} end,
        question: "What is Elixir?"
      ]

      assert {:ok, %Result{answer: "stub answer"}} = Answering.ask("Prompt", opts)
    end

    test "succeeds when set_prompt_fn returns :ok" do
      opts = [
        agent_mod: StubAgent,
        set_prompt_fn: fn _server, _prompt -> :ok end
      ]

      assert {:ok, %Result{answer: "stub answer"}} = Answering.ask("Prompt", opts)
    end

    test "returns error when set_prompt_fn returns {:error, reason}" do
      opts = [
        agent_mod: StubAgent,
        set_prompt_fn: fn _server, _prompt -> {:error, "prompt rejected"} end
      ]

      assert {:error, message} = Answering.ask("Prompt", opts)
      assert String.contains?(message, "Failed to start answering agent")
    end

    test "handles empty messages (no question, no history)" do
      opts = [
        agent_mod: StubAgent,
        set_prompt_fn: fn _server, _prompt -> :ok end
      ]

      assert {:ok, %Result{answer: "stub answer"}} = Answering.ask("Prompt", opts)
    end

    test "handles mixed history with user and bot messages" do
      history = %{
        "1" => %{"body" => "What is Elixir?", "type" => "user"},
        "2" => %{"body" => "A functional language.", "type" => "bot"}
      }

      opts = [
        agent_mod: StubAgent,
        set_prompt_fn: fn _server, _prompt -> :ok end,
        history: history,
        question: "Tell me more."
      ]

      assert {:ok, %Result{answer: "stub answer"}} = Answering.ask("Prompt", opts)
    end

    test "handles list-typed question content (content_to_string list branch)" do
      opts = [
        agent_mod: StubAgent,
        set_prompt_fn: fn _server, _prompt -> :ok end,
        question: [%{text: "What is Elixir?"}, %{other_key: "ignored"}]
      ]

      assert {:ok, %Result{answer: "stub answer"}} = Answering.ask("Prompt", opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Confidence scoring via logprobs (covers emit_answer_telemetry branches
  # and all confidence_bucket_metric clauses)
  # ---------------------------------------------------------------------------

  describe "confidence scoring via logprobs (non-run_fn path)" do
    setup do
      on_exit(fn -> Process.delete(:stub_logprob) end)
      :ok
    end

    test "records confidence telemetry when logprobs yield score > 0.9 (gt_90 bucket)" do
      Process.put(:stub_logprob, -0.05)

      opts = [
        agent_mod: StubAgentWithLogprobs,
        set_prompt_fn: fn _server, _prompt -> :ok end
      ]

      assert {:ok, %Result{confidence_score: score}} = Answering.ask("Prompt", opts)
      assert is_float(score)
      assert score > 0.9
    end

    test "confidence bucket between_80_90 (score > 0.8 and <= 0.9)" do
      Process.put(:stub_logprob, -0.18)

      opts = [
        agent_mod: StubAgentWithLogprobs,
        set_prompt_fn: fn _server, _prompt -> :ok end
      ]

      assert {:ok, %Result{confidence_score: score}} = Answering.ask("Prompt", opts)
      assert is_float(score)
      assert score > 0.8 and score <= 0.9
    end

    test "confidence bucket between_70_80 (score > 0.7 and <= 0.8)" do
      Process.put(:stub_logprob, -0.28)

      opts = [
        agent_mod: StubAgentWithLogprobs,
        set_prompt_fn: fn _server, _prompt -> :ok end
      ]

      assert {:ok, %Result{confidence_score: score}} = Answering.ask("Prompt", opts)
      assert is_float(score)
      assert score > 0.7 and score <= 0.8
    end

    test "confidence bucket between_50_70 (score >= 0.5 and <= 0.7)" do
      Process.put(:stub_logprob, -0.6)

      opts = [
        agent_mod: StubAgentWithLogprobs,
        set_prompt_fn: fn _server, _prompt -> :ok end
      ]

      assert {:ok, %Result{confidence_score: score}} = Answering.ask("Prompt", opts)
      assert is_float(score)
      assert score >= 0.5 and score <= 0.7
    end

    test "confidence bucket lt_50 (score < 0.5)" do
      Process.put(:stub_logprob, -1.5)

      opts = [
        agent_mod: StubAgentWithLogprobs,
        set_prompt_fn: fn _server, _prompt -> :ok end
      ]

      assert {:ok, %Result{confidence_score: score}} = Answering.ask("Prompt", opts)
      assert is_float(score)
      assert score < 0.5
    end
  end

  # ---------------------------------------------------------------------------
  # normalize_dimensions catch-all
  # ---------------------------------------------------------------------------

  describe "normalize_dimensions/1 catch-all" do
    test "non-map telemetry_dimensions is normalised to empty map without crash" do
      opts = [
        run_fn: fn _prompt, _msgs, _opts -> {:ok, "The answer"} end,
        telemetry_dimensions: :not_a_map
      ]

      assert {:ok, %Result{answer: "The answer"}} = Answering.ask("Prompt", opts)
    end
  end

  defp upsert_prompt_template(attrs) do
    case PromptTemplate.get_by_slug(attrs.slug) do
      nil -> PromptTemplate.create(attrs)
      template -> PromptTemplate.update(template, attrs)
    end
  end
end
