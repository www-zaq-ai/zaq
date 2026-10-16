defmodule Zaq.Contracts.AnswerOutcomeTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.AnswerOutcome

  defp attributes do
    %{
      submission: "accepted",
      input: "consumed",
      execution: "running",
      persistence: "not_persisted",
      delivery: "not_attempted",
      history: "not_associated"
    }
  end

  test "execution completion does not imply delivery or history association" do
    attrs = %{attributes() | execution: "completed", persistence: "persisted"}
    assert {:ok, outcome} = AnswerOutcome.new(attrs)
    assert outcome.delivery == "not_attempted"
    assert outcome.history == "not_associated"
  end

  test "unknown execution observation does not claim failure or cancellation" do
    assert {:ok, outcome} = AnswerOutcome.new(%{attributes() | execution: "unknown"})
    assert outcome.execution == "unknown"
    assert outcome.persistence == "not_persisted"
  end

  test "suppression, failure and cancellation do not require an assistant history row" do
    for execution <- ~w(suppressed failed cancelled) do
      assert {:ok, _} = AnswerOutcome.new(%{attributes() | execution: execution})
    end
  end

  test "queued receipt describes the shared root without claiming consumption" do
    assert {:ok, _} = AnswerOutcome.new(%{attributes() | input: "queued"})

    assert {:ok, _} =
             AnswerOutcome.new(%{attributes() | input: "unconsumed", execution: "completed"})
  end

  test "rejection is distinct from execution failure" do
    rejected = %{
      attributes()
      | submission: "rejected",
        input: "not_applicable",
        execution: "not_started"
    }

    assert {:ok, _} = AnswerOutcome.new(rejected)

    assert {:error, :invalid_answer_outcome} =
             AnswerOutcome.new(%{rejected | execution: "running"})
  end

  test "contradictory persistence and history claims fail closed" do
    for attrs <- [
          %{attributes() | history: "associated"},
          %{attributes() | persistence: "persisted"},
          %{attributes() | execution: "failed", persistence: "persisted"},
          %{attributes() | submission: "rejected"}
        ] do
      assert {:error, :invalid_answer_outcome} = AnswerOutcome.new(attrs)
    end
  end

  test "accepts only complete bounded allowlisted facts and JSON round trips" do
    assert {:ok, outcome} = AnswerOutcome.new(attributes())
    public = AnswerOutcome.to_map(outcome)
    assert {:ok, ^outcome} = public |> Jason.encode!() |> Jason.decode!() |> AnswerOutcome.new()

    for key <- Map.keys(attributes()) do
      assert {:error, :invalid_answer_outcome} = AnswerOutcome.new(Map.delete(attributes(), key))

      assert {:error, :invalid_answer_outcome} =
               AnswerOutcome.new(Map.put(attributes(), key, "other"))
    end

    assert {:error, :invalid_answer_outcome} =
             AnswerOutcome.new(Map.put(attributes(), :trace, []))

    assert {:error, :invalid_answer_outcome} =
             AnswerOutcome.new(Map.put(attributes(), "execution", "failed"))

    assert {:error, :invalid_answer_outcome} = AnswerOutcome.new(nil)
  end
end
