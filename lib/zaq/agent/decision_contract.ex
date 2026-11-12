defmodule Zaq.Agent.DecisionContract do
  @moduledoc """
  Pure schemas and normalization for named, model-independent decisions.

  Dynamic identifiers stay string-keyed data. Provider probabilities are preserved,
  never completed, recalibrated or used to override the provider's chosen value.
  """

  defp question_schema do
    Zoi.discriminated_union("type", [
      Zoi.object(
        %{
          "type" => Zoi.literal("choice"),
          "instructions" => text(),
          "criteria" => Zoi.map(text(), text()) |> Zoi.refine({__MODULE__, :at_least_two, []})
        },
        unrecognized_keys: :error
      ),
      Zoi.object(
        %{
          "type" => Zoi.literal("boolean"),
          "instructions" => text(),
          "threshold" => probability() |> Zoi.default(0.5)
        },
        unrecognized_keys: :error
      ),
      Zoi.object(
        %{
          "type" => Zoi.literal("score"),
          "instructions" => text(),
          "criteria" =>
            Zoi.list(text())
            |> Zoi.min(2)
            |> Zoi.refine({__MODULE__, :distinct_labels, []})
        },
        unrecognized_keys: :error
      )
    ])
  end

  @doc "Input schema shared by validated code, agent and workflow execution."
  @spec input_schema() :: Zoi.schema()
  def input_schema do
    Zoi.object(%{
      state:
        Zoi.union([Zoi.string(), Zoi.map(), Zoi.list(Zoi.any())],
          description: "Text or JSON object/array to evaluate; no data is fetched automatically."
        )
        |> Zoi.refine({__MODULE__, :json_state, []}),
      questions:
        Zoi.map(text(), question_schema(),
          description:
            "Named questions: each value must be a typed object with type and instructions, not a question string. Use dot-free IDs for workflow paths."
        )
        |> Zoi.refine({__MODULE__, :non_empty_questions, []})
    })
  end

  @doc "Model-facing schema retaining the typed values of named question and criteria maps."
  @spec tool_schema() :: map()
  def tool_schema do
    # Zoi's key/value map encoder emits only `type: object`. Keep validation in
    # Zoi, and restore those two map-value schemas at the tool export boundary.
    questions =
      question_schema()
      |> json_schema()
      |> Map.delete("$schema")
      |> Map.update!("oneOf", &Enum.map(&1, fn branch -> describe_question(branch) end))

    input_schema()
    |> json_schema()
    |> put_in(["properties", "questions", "additionalProperties"], questions)
    |> put_in(["properties", "questions", "minProperties"], 1)
    |> put_in(["properties", "questions", "propertyNames"], %{"minLength" => 1})
    |> put_in(["properties", "questions", "examples"], [example_questions()])
    |> update_in(["properties", "state", "anyOf"], fn branches ->
      Enum.map(branches, fn
        %{"type" => "object"} = branch -> Map.put(branch, "additionalProperties", true)
        branch -> branch
      end)
    end)
  end

  defp json_schema(schema),
    do: schema |> Zoi.to_json_schema() |> Jason.encode!() |> Jason.decode!()

  defp describe_question(branch) do
    branch
    |> put_in(["properties", "type", "type"], "string")
    |> put_in(
      ["properties", "instructions", "description"],
      "Question to answer using the supplied state."
    )
    |> put_in(["properties", "instructions", "minLength"], 1)
    |> describe_criteria()
  end

  defp describe_criteria(%{"properties" => %{"type" => %{"const" => "choice"}}} = branch) do
    put_in(branch, ["properties", "criteria"], %{
      "type" => "object",
      "description" =>
        "At least two option IDs mapped to their descriptions. Not an options list or a string.",
      "minProperties" => 2,
      "additionalProperties" => %{"type" => "string", "minLength" => 1}
    })
  end

  defp describe_criteria(%{"properties" => %{"type" => %{"const" => "boolean"}}} = branch) do
    Map.update!(branch, "required", &List.delete(&1, "threshold"))
  end

  defp describe_criteria(branch) do
    branch
    |> put_in(["properties", "criteria", "uniqueItems"], true)
    |> put_in(
      ["properties", "criteria", "description"],
      "Distinct ordered rubric labels from lowest to highest. Scores are zero-based and may be fractional."
    )
  end

  defp example_questions do
    %{
      "category" => %{
        "type" => "choice",
        "instructions" => "Classify this feedback.",
        "criteria" => %{
          "complaint" => "Dissatisfaction",
          "bug" => "A defect report",
          "compliment" => "Praise"
        }
      },
      "support_intervention" => %{
        "type" => "boolean",
        "instructions" => "Should customer support intervene?"
      },
      "urgency" => %{
        "type" => "score",
        "instructions" => "Assess urgency.",
        "criteria" => ["Routine", "Critical"]
      }
    }
  end

  @doc "JSON-safe result schema; absent distributions and confidence remain null."
  @spec output_schema() :: Zoi.schema()
  def output_schema do
    Zoi.object(%{
      decisions:
        Zoi.map(
          Zoi.string(),
          Zoi.discriminated_union("type", [
            answer_schema("choice", Zoi.string()),
            answer_schema("score", Zoi.number()),
            Zoi.object(%{
              "type" => Zoi.literal("boolean"),
              "value" => Zoi.boolean(),
              "probability" => probability(),
              "threshold" => probability()
            })
          ])
        )
    })
  end

  defp answer_schema(type, value) do
    Zoi.object(%{
      "type" => Zoi.literal(type),
      "value" => value,
      "confidence" => probability() |> Zoi.nullable(),
      "probabilities" => Zoi.map(Zoi.string(), probability()) |> Zoi.nullable()
    })
  end

  defp text, do: Zoi.string() |> Zoi.refine({__MODULE__, :non_blank, []})
  defp probability, do: Zoi.number() |> Zoi.min(0) |> Zoi.max(1)

  @doc "Zoi refinement requiring non-blank UTF-8 identifiers and instructions."
  @spec non_blank(String.t(), keyword()) :: :ok | {:error, String.t()}
  def non_blank(value, _opts) do
    if String.valid?(value) and String.trim(value) != "",
      do: :ok,
      else: {:error, "must not be blank"}
  end

  @doc "Zoi refinement requiring a choice between at least two options."
  @spec at_least_two(map(), keyword()) :: :ok | {:error, String.t()}
  def at_least_two(criteria, _opts) do
    if map_size(criteria) >= 2, do: :ok, else: {:error, "at least two choices are required"}
  end

  @doc "Zoi refinement rejecting an empty evaluation request."
  @spec non_empty_questions(map(), keyword()) :: :ok | {:error, String.t()}
  def non_empty_questions(questions, _opts) do
    if map_size(questions) > 0, do: :ok, else: {:error, "at least one question is required"}
  end

  @doc "Zoi refinement keeping ordered rubric labels unambiguous."
  @spec distinct_labels(list(), keyword()) :: :ok | {:error, String.t()}
  def distinct_labels(labels, _opts) do
    if length(Enum.uniq(labels)) == length(labels),
      do: :ok,
      else: {:error, "rubric labels must be distinct"}
  end

  @doc "Zoi refinement excluding non-JSON values from supplied state."
  @spec json_state(term(), keyword()) :: :ok | {:error, String.t()}
  def json_state(state, _opts) do
    if json?(state), do: :ok, else: {:error, "state must contain only JSON values"}
  end

  @doc "Normalizes native field keys without creating atoms or discarding key collisions."
  @spec prepare_input(map()) :: {:ok, map()} | {:error, :invalid_input}
  def prepare_input(params) do
    with {:ok, normalized} <-
           stringify(Map.take(params, [:state, "state", :questions, "questions"])) do
      questions =
        case normalized["questions"] do
          questions when is_map(questions) -> Map.new(questions, &normalize_question/1)
          other -> other
        end

      {:ok, normalized |> Map.put("questions", questions)}
    end
  end

  defp normalize_question({id, question}) when is_map(question) do
    question =
      case question["type"] do
        type when type in [:boolean, :choice, :score] ->
          Map.put(question, "type", Atom.to_string(type))

        _ ->
          question
      end

    {id, question}
  end

  defp normalize_question(pair), do: pair

  defp stringify(%_{}), do: {:error, :invalid_input}

  defp stringify(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      with true <- is_atom(key) or is_binary(key),
           key = to_string(key),
           false <- Map.has_key?(acc, key),
           {:ok, normalized} <- stringify(item) do
        {:cont, {:ok, Map.put(acc, key, normalized)}}
      else
        _ -> {:halt, {:error, :invalid_input}}
      end
    end)
  end

  defp stringify(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case stringify(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp stringify(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: {:ok, value}

  defp stringify(_value), do: {:error, :invalid_input}

  defp json?(%_{}), do: false

  defp json?(value) when is_map(value),
    do:
      Enum.all?(value, fn {key, item} -> is_binary(key) and String.valid?(key) and json?(item) end)

  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value), do: is_number(value) or is_boolean(value) or is_nil(value)

  @doc "Validates all named answers and returns one normalized, complete decision map."
  @spec normalize_answers(term(), map()) :: {:ok, map()} | {:error, :invalid_response | :refused}
  def normalize_answers(answers, questions) when is_map(answers) do
    if MapSet.new(Map.keys(answers)) == MapSet.new(Map.keys(questions)) do
      normalize_named_answers(answers, questions)
    else
      {:error, :invalid_response}
    end
  end

  def normalize_answers(_answers, _questions), do: {:error, :invalid_response}

  defp normalize_named_answers(answers, questions) do
    Enum.reduce_while(questions, {:ok, %{}}, fn {id, question}, {:ok, acc} ->
      case normalize_answer(answers[id], question) do
        {:ok, answer} -> {:cont, {:ok, Map.put(acc, id, answer)}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize_answer(%{"type" => "refusal"}, _question), do: {:error, :refused}

  defp normalize_answer(
         %{"type" => "boolean", "probability" => value},
         %{"type" => "boolean"} = question
       ) do
    if probability?(value) do
      threshold = question["threshold"]

      {:ok,
       %{
         "type" => "boolean",
         "value" => value >= threshold,
         "probability" => value,
         "threshold" => threshold
       }}
    else
      {:error, :invalid_response}
    end
  end

  defp normalize_answer(%{"type" => type} = answer, %{"type" => type} = question)
       when type in ["choice", "score"] do
    value = if type == "choice", do: answer["choice"], else: answer["score"]
    confidence = answer["confidence"]

    with true <- valid_value?(value, question),
         true <- is_nil(confidence) or probability?(confidence),
         {:ok, probabilities} <- normalize_probabilities(answer["probabilities"], question) do
      {:ok,
       %{
         "type" => type,
         "value" => value,
         "confidence" => confidence,
         "probabilities" => probabilities
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_answer(_answer, _question), do: {:error, :invalid_response}

  defp valid_value?(value, %{"type" => "choice", "criteria" => criteria}),
    do: is_binary(value) and Map.has_key?(criteria, value)

  defp valid_value?(value, %{"type" => "score", "criteria" => criteria}),
    do: is_number(value) and value >= 0 and value <= length(criteria) - 1

  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1

  defp normalize_probabilities(value, _question) when value in [nil, []], do: {:ok, nil}

  defp normalize_probabilities(value, _question) when is_map(value) and map_size(value) == 0,
    do: {:ok, nil}

  defp normalize_probabilities(value, question) when is_map(value) or is_list(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn entry, {:ok, acc} ->
      with {:ok, key, probability} <- probability_entry(entry),
           {:ok, key} <- probability_key(key, question),
           true <- probability?(probability),
           false <- Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, probability)}}
      else
        _ -> {:halt, {:error, :invalid_response}}
      end
    end)
  end

  defp normalize_probabilities(_value, _question), do: {:error, :invalid_response}
  defp probability_entry({key, value}), do: {:ok, key, value}
  defp probability_entry(%{"value" => key, "probability" => value}), do: {:ok, key, value}
  defp probability_entry(_entry), do: {:error, :invalid_response}

  defp probability_key(key, %{"type" => "choice", "criteria" => criteria}) do
    if is_binary(key) and Map.has_key?(criteria, key),
      do: {:ok, key},
      else: {:error, :invalid_response}
  end

  defp probability_key(key, %{"type" => "score", "criteria" => criteria}) do
    indices = Enum.map(0..(length(criteria) - 1), &Integer.to_string/1)
    key = if is_integer(key), do: Integer.to_string(key), else: key
    if key in indices, do: {:ok, key}, else: {:error, :invalid_response}
  end
end
