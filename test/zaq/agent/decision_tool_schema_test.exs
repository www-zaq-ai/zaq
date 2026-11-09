defmodule Zaq.Agent.DecisionToolSchemaTest do
  use ExUnit.Case, async: true

  alias Jido.AI.ToolAdapter
  alias Zaq.Agent.Actions.EvaluateDecisions

  test "the actual agent tool exposes all named question types and their required fields" do
    tool = ToolAdapter.from_action(EvaluateDecisions)
    questions = json_schema(tool)["properties"]["questions"]
    assert questions["type"] == "object"
    assert questions["minProperties"] == 1
    assert is_map(questions["additionalProperties"])

    branches =
      Map.new(
        questions["additionalProperties"]["oneOf"],
        &{&1["properties"]["type"]["const"], &1}
      )

    assert Map.keys(branches) |> Enum.sort() == ["boolean", "choice", "score"]

    for {_type, branch} <- branches do
      assert "type" in branch["required"]
      assert "instructions" in branch["required"]
      assert branch["properties"]["instructions"]["type"] == "string"
      assert branch["additionalProperties"] == false
    end

    choice = branches["choice"]
    assert "criteria" in choice["required"]
    assert choice["properties"]["criteria"]["additionalProperties"]["type"] == "string"
    assert choice["properties"]["criteria"]["minProperties"] == 2
    refute Map.has_key?(choice["properties"], "options")
    boolean = branches["boolean"]
    refute "threshold" in boolean["required"]
    assert boolean["properties"]["threshold"]["default"] == 0.5
    assert boolean["properties"]["threshold"]["minimum"] == 0
    assert boolean["properties"]["threshold"]["maximum"] == 1
    refute Map.has_key?(boolean["properties"], "criteria")
    assert branches["score"]["properties"]["criteria"]["items"]["type"] == "string"
    assert branches["score"]["properties"]["criteria"]["uniqueItems"]
    assert questions["examples"] != []
    assert tool.description =~ "criteria"
    refute tool.strict
  end

  test "model-facing JSON state accepts arbitrary object keys instead of a closed empty object" do
    tool = ToolAdapter.from_action(EvaluateDecisions)
    state = json_schema(tool)["properties"]["state"]
    object = Enum.find(state["anyOf"], &(&1["type"] == "object"))
    assert object["additionalProperties"] == true
  end

  test "published question examples pass the same validation as actual tool execution" do
    [example] =
      json_schema(ToolAdapter.from_action(EvaluateDecisions))["properties"]["questions"][
        "examples"
      ]

    assert {:ok, validated} =
             EvaluateDecisions.validate_params(%{
               "state" => %{"feedback" => "Amazing product"},
               "questions" => example
             })

    assert validated.questions["support_intervention"]["threshold"] == 0.5
    assert validated.questions["category"]["criteria"]["compliment"] == "Praise"
  end

  test "the reported seven malformed question shapes return actionable field paths" do
    boolean = %{"type" => "boolean", "instructions" => "Should support intervene?"}
    choice = %{"type" => "choice", "instructions" => "Classify feedback."}
    options = ["Complain", "Bug sharing", "Compliment"]

    attempts = [
      {%{"category" => "Which category?", "support_intervention" => "Support needed?"},
       "questions.category"},
      {%{
         "category" => %{"type" => "choice", "options" => options},
         "support_intervention" => %{"type" => "boolean"}
       }, "questions.category.criteria"},
      {%{
         "category" =>
           Map.merge(choice, %{"criteria" => "Classify content", "options" => options}),
         "support_intervention" => boolean
       }, "questions.category.criteria"},
      {%{
         "category" => "Classify as Complain, Bug sharing, or Compliment",
         "support_intervention" => "Support needed?"
       }, "questions.category"},
      {%{
         "category" => Map.put(choice, "criteria", "Classify content"),
         "support_intervention" => Map.put(boolean, "criteria", "Intervention")
       }, "questions.support_intervention"},
      {%{
         "category" => %{
           "criteria" => %{"options" => options, "type" => "choice"},
           "instructions" => "Classify"
         },
         "support_intervention" => %{
           "criteria" => %{"type" => "boolean"},
           "instructions" => "Intervene?"
         }
       }, "questions.category.type"},
      {%{
         "category" => Map.put(choice, "criteria", %{"options" => options, "type" => "choice"}),
         "support_intervention" => Map.put(boolean, "criteria", %{"type" => "boolean"})
       }, "questions.category.criteria.options"}
    ]

    for {questions, path} <- attempts do
      assert {:error, error} =
               EvaluateDecisions.validate_params(%{
                 state: "Amazing product",
                 questions: questions
               })

      assert Exception.message(error) =~ path
    end
  end

  defp json_schema(tool), do: Jason.decode!(Jason.encode!(tool.parameter_schema))
end
