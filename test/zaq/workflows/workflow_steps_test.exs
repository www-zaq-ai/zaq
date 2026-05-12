defmodule Zaq.Workflows.WorkflowStepsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Workflows.Workflow

  @valid_steps %{
    "nodes" => [
      %{
        "name" => "fetch",
        "type" => "action",
        "module" => "Zaq.Agent.Tools.Email.FetchEmails",
        "params" => %{},
        "index" => 0
      }
    ],
    "edges" => [
      %{"from" => "fetch", "to" => "draft"}
    ]
  }

  describe "steps validation — draft status" do
    test "accepts empty steps when status is draft" do
      changeset = Workflow.changeset(%Workflow{}, %{name: "W", status: "draft", steps: %{}})
      assert changeset.valid?
    end

    test "accepts steps without nodes/edges when status is draft" do
      changeset =
        Workflow.changeset(%Workflow{}, %{name: "W", status: "draft", steps: %{"step1" => %{}}})

      assert changeset.valid?
    end
  end

  describe "steps validation — active status" do
    test "accepts well-formed steps when activating" do
      changeset =
        Workflow.changeset(%Workflow{}, %{name: "W", status: "active", steps: @valid_steps})

      assert changeset.valid?
    end

    test "rejects steps missing nodes key when activating" do
      steps = Map.delete(@valid_steps, "nodes")
      changeset = Workflow.changeset(%Workflow{}, %{name: "W", status: "active", steps: steps})
      refute changeset.valid?
      assert changeset.errors[:steps]
    end

    test "rejects steps missing edges key when activating" do
      steps = Map.delete(@valid_steps, "edges")
      changeset = Workflow.changeset(%Workflow{}, %{name: "W", status: "active", steps: steps})
      refute changeset.valid?
      assert changeset.errors[:steps]
    end

    test "rejects empty steps when activating" do
      changeset = Workflow.changeset(%Workflow{}, %{name: "W", status: "active", steps: %{}})
      refute changeset.valid?
      assert changeset.errors[:steps]
    end
  end

  describe "steps validation — archived status" do
    test "does not re-validate steps format when archiving" do
      existing = %Workflow{name: "W", status: "active", steps: @valid_steps, settings: %{}}
      changeset = Workflow.changeset(existing, %{status: "archived"})
      assert changeset.valid?
    end
  end
end
