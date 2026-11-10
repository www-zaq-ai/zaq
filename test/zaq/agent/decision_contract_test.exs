defmodule Zaq.Agent.DecisionContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Action.Tool
  alias Zaq.Agent.DecisionContract

  property "boolean thresholds preserve probability and compare inclusively across the unit interval" do
    check all(p <- integer(0..1000), t <- integer(0..1000)) do
      probability = p / 1000
      threshold = t / 1000
      questions = %{"answer" => %{"type" => "boolean", "threshold" => threshold}}
      response = %{"answer" => %{"type" => "boolean", "probability" => probability}}

      assert {:ok, %{"answer" => answer}} =
               DecisionContract.normalize_answers(response, questions)

      assert answer["value"] == probability >= threshold
      assert answer["probability"] == probability
      assert answer["threshold"] == threshold

      assert {:ok, _} =
               Zoi.parse(DecisionContract.output_schema(), %{decisions: %{"answer" => answer}})
    end
  end

  property "choice distributions preserve every supplied key and zero without renormalizing" do
    check all(values <- list_of(integer(0..1000), min_length: 2, max_length: 12)) do
      pairs = Enum.with_index(values, fn value, i -> {"option_#{i}", value / 1000} end)
      distribution = Map.new(pairs)

      questions = %{
        "choose" => %{
          "type" => "choice",
          "criteria" => Map.new(pairs, fn {key, _} -> {key, key} end)
        }
      }

      answers = %{
        "choose" => %{"type" => "choice", "choice" => "option_0", "probabilities" => distribution}
      }

      assert {:ok, %{"choose" => answer}} = DecisionContract.normalize_answers(answers, questions)
      assert answer["probabilities"] === distribution
      assert answer["confidence"] == nil
      assert answer["value"] == "option_0"
    end
  end

  test "preserves false and zero while rejecting missing, unknown and duplicate probability entries" do
    question = %{"score" => %{"type" => "score", "criteria" => ["Low", "High"]}}

    for distribution <- [nil, %{}, []] do
      answers = %{
        "score" => %{
          "type" => "score",
          "score" => 0,
          "confidence" => 0,
          "probabilities" => distribution
        }
      }

      assert {:ok, %{"score" => %{"value" => 0, "confidence" => 0, "probabilities" => nil}}} =
               DecisionContract.normalize_answers(answers, question)
    end

    for distribution <- [
          %{"2" => 0.5},
          %{"0" => -0.1},
          [%{"value" => 0, "probability" => 0.5}, %{"value" => "0", "probability" => 0.5}],
          "PRIVATE"
        ] do
      answers = %{"score" => %{"type" => "score", "score" => 0, "probabilities" => distribution}}
      assert {:error, :invalid_response} = DecisionContract.normalize_answers(answers, question)
    end

    assert {:error, :invalid_response} = DecisionContract.normalize_answers(%{}, question)
    assert {:error, :invalid_response} = DecisionContract.normalize_answers(nil, question)
  end

  test "state rejects structs and native values that are not JSON, including nested key collisions" do
    questions = %{"ok" => %{type: :boolean, instructions: "Decide"}}

    for state <- [self(), make_ref(), %{nested: %{:a => 1, "a" => 2}}, Date.utc_today()] do
      assert {:error, :invalid_input} =
               DecisionContract.prepare_input(%{state: state, questions: questions})
    end

    assert {:ok, normalized} =
             DecisionContract.prepare_input(%{state: %{value: :not_json}, questions: questions})

    assert {:error, _} =
             Zoi.parse(
               DecisionContract.input_schema(),
               Tool.convert_params_using_schema(normalized, DecisionContract.input_schema())
             )
  end

  test "non-map questions survive preparation and fail public validation" do
    assert {:ok, %{"state" => "context", "questions" => ["not a question map"]} = normalized} =
             DecisionContract.prepare_input(%{
               state: "context",
               questions: ["not a question map"]
             })

    assert {:error, _} =
             Zoi.parse(
               DecisionContract.input_schema(),
               Tool.convert_params_using_schema(normalized, DecisionContract.input_schema())
             )
  end

  test "a nested invalid list item propagates its preparation error" do
    assert {:error, :invalid_input} =
             DecisionContract.prepare_input(%{
               state: %{events: ["valid", make_ref()]},
               questions: %{"ok" => %{type: :boolean, instructions: "Decide"}}
             })
  end

  test "the public JSON-state refinement rejects a struct" do
    assert DecisionContract.json_state(%Date{year: 2024, month: 1, day: 1}, []) ==
             {:error, "state must contain only JSON values"}
  end

  test "malformed and type-mismatched named answers return the exact error" do
    questions = %{
      "decision" => %{"type" => "choice", "criteria" => %{"yes" => "Yes", "no" => "No"}}
    }

    for answer <- [nil, %{"type" => "score", "score" => 0}] do
      assert {:error, :invalid_response} =
               DecisionContract.normalize_answers(%{"decision" => answer}, questions)
    end
  end

  test "a malformed probability-list entry returns the exact error" do
    questions = %{
      "decision" => %{"type" => "choice", "criteria" => %{"yes" => "Yes", "no" => "No"}}
    }

    answers = %{
      "decision" => %{
        "type" => "choice",
        "choice" => "yes",
        "probabilities" => [%{"value" => "yes"}]
      }
    }

    assert {:error, :invalid_response} = DecisionContract.normalize_answers(answers, questions)
  end
end
