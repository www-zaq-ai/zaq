defmodule Zaq.Agent.AnsweringCoverageTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Answering
  alias Zaq.Agent.Answering.Result
  alias Zaq.Agent.PromptTemplate

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

  defp upsert_prompt_template(attrs) do
    case PromptTemplate.get_by_slug(attrs.slug) do
      nil -> PromptTemplate.create(attrs)
      template -> PromptTemplate.update(template, attrs)
    end
  end
end
