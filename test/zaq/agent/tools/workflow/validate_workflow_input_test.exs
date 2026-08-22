defmodule Zaq.Agent.Tools.Workflow.ValidateWorkflowInputTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.Workflow.ValidateWorkflowInput
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Workflow
  alias Zaq.Repo

  # Inserted through the changeset rather than `Workflows.create_workflow/2` so
  # the fixture does not have to stub the `workflow.created` NodeRouter dispatch.
  defp workflow_fixture do
    Repo.insert!(
      Workflow.changeset(%Workflow{}, %{
        "name" => "Send Leads Email",
        "status" => "draft",
        "nodes" => [
          %{
            "name" => "ensure_person",
            "type" => "action",
            "module" => "Zaq.Agent.Tools.People.EnsurePerson",
            "index" => 0,
            "params" => %{"platform" => "email"}
          },
          %{
            "name" => "build_history",
            "type" => "action",
            "module" => "Zaq.Agent.Tools.Accounts.History",
            "index" => 1,
            "params" => %{"query" => "a default", "search_in" => "title"}
          },
          %{
            "name" => "build_agent_context",
            "type" => "action",
            "module" => "Zaq.Agent.Tools.Workflow.Concat",
            "index" => 2,
            "params" => %{"parts" => ["{{start.company context content}}"]}
          }
        ],
        "edges" => [
          %{
            "from" => "ensure_person",
            "to" => "build_history",
            "mapping" => %{
              "query" => "start.email topic",
              "person_id" => "ensure_person.person.id"
            }
          },
          %{"from" => "build_history", "to" => "build_agent_context", "mapping" => %{}}
        ]
      })
    )
  end

  describe "run/2" do
    test "reports every payload path the workflow reads" do
      workflow = workflow_fixture()

      assert {:ok, %{required_inputs: ["company context content", "email topic"]}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})
    end

    test "rejects a payload missing a required field" do
      workflow = workflow_fixture()

      assert {:ok, result} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: %{"email topic" => "Q3"}},
                 %{}
               )

      refute result.valid
      assert result.missing_inputs == ["company context content"]
      assert result.input == %{"email topic" => "Q3"}
    end

    test "accepts a payload supplying every required field" do
      workflow = workflow_fixture()

      assert {:ok, %{valid: true, missing_inputs: []}} =
               ValidateWorkflowInput.run(
                 %{
                   workflow_id: workflow.id,
                   input: %{"email topic" => "Q3", "company context content" => "ctx"}
                 },
                 %{}
               )
    end

    test "accepts differently-cased keys the way FactLookup will at run time" do
      workflow = workflow_fixture()

      assert {:ok, %{valid: true}} =
               ValidateWorkflowInput.run(
                 %{
                   workflow_id: workflow.id,
                   input: %{"Email_Topic" => "Q3", "Company Context Content" => "ctx"}
                 },
                 %{}
               )
    end

    test "a failing verdict is {:ok, _} so an edge can route it, never {:error, _}" do
      workflow = workflow_fixture()

      assert {:ok, %{valid: false}} = ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})
    end

    test "defaults input to an empty map" do
      workflow = workflow_fixture()

      assert {:ok, %{input: %{}}} = ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})
    end

    test "reports inputs the graph cannot trace as unknown, not as required" do
      workflow = workflow_fixture()

      assert {:ok, %{unsatisfiable_inputs: []}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})
    end

    test "returns the contract as a fillable shape, not only as paths" do
      workflow = workflow_fixture()

      assert {:ok, %{required_input_shape: shape}} =
               ValidateWorkflowInput.run(%{workflow_id: workflow.id}, %{})

      assert shape == %{"company context content" => nil, "email topic" => nil}
    end

    test "returns an error for an unknown workflow" do
      assert {:error, message} =
               ValidateWorkflowInput.run(%{workflow_id: Ecto.UUID.generate()}, %{})

      assert message =~ "workflow not found"
    end

    test "returns an error rather than raising for a non-uuid workflow_id" do
      assert {:error, message} = ValidateWorkflowInput.run(%{workflow_id: "not-a-uuid"}, %{})
      assert message =~ "not a valid uuid"
    end

    test "returns an error for a non-string workflow_id" do
      assert {:error, message} = ValidateWorkflowInput.run(%{workflow_id: 42}, %{})
      assert message =~ "not a valid uuid"
    end
  end

  describe "schema" do
    test "workflow_id is required and input is not" do
      fields = Map.new(ValidateWorkflowInput.schema().fields)

      assert fields[:workflow_id].meta.required
      refute fields[:input].meta.required
    end

    # `input` carrying `meta.required` would make every workflow using this action
    # as a node report a phantom `input` requirement, since
    # `InputContract.required_schema_fields/1` reads that flag. `Zoi.default/2`
    # alone does not clear it — only `Zoi.optional/1` does.
    test "the action contributes no phantom required field to a contract" do
      assert InputContract.required_schema_fields(inspect(ValidateWorkflowInput)) ==
               ["workflow_id"]
    end

    # A scalar payload must reach `run/2` and come back as an invalid verdict, not
    # be rejected at schema validation.
    test "input accepts a non-map payload" do
      assert {:ok, %{input: "not a map"}} =
               Zoi.parse(
                 ValidateWorkflowInput.schema(),
                 %{workflow_id: Ecto.UUID.generate(), input: "not a map"}
               )
    end

    test "a scalar payload is reported invalid rather than raising" do
      workflow = workflow_fixture()

      assert {:ok, %{valid: false, input: "not a map"}} =
               ValidateWorkflowInput.run(
                 %{workflow_id: workflow.id, input: "not a map"},
                 %{}
               )
    end
  end
end
