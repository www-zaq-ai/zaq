defmodule Zaq.Engine.Workflows.WorkflowStepsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows.Workflow

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Agent.Tools.Email.FetchEmails",
    params: %{},
    index: 0
  }
  @valid_edge %{from: "fetch", to: "draft"}

  describe "nodes validation — draft status" do
    test "accepts empty nodes when status is draft" do
      changeset =
        Workflow.changeset(%Workflow{}, %{name: "W", status: "draft", nodes: [], edges: []})

      assert changeset.valid?
    end

    test "accepts no nodes/edges keys at all when status is draft" do
      changeset = Workflow.changeset(%Workflow{}, %{name: "W", status: "draft"})
      assert changeset.valid?
    end
  end

  describe "nodes validation — active status" do
    test "accepts well-formed nodes and edges when activating" do
      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [@valid_edge]
        })

      assert changeset.valid?
    end

    test "rejects empty nodes when activating" do
      changeset =
        Workflow.changeset(%Workflow{}, %{name: "W", status: "active", nodes: [], edges: []})

      refute changeset.valid?
      assert changeset.errors[:nodes]
    end

    test "rejects node missing required name field" do
      bad_node = Map.delete(@valid_node, :name)

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [bad_node],
          edges: []
        })

      refute changeset.valid?
    end

    test "rejects node with unknown type" do
      bad_node = %{@valid_node | type: "magic"}

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [bad_node],
          edges: []
        })

      refute changeset.valid?
    end

    test "rejects action node missing module" do
      bad_node = Map.delete(@valid_node, :module)

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [bad_node],
          edges: []
        })

      refute changeset.valid?
    end

    test "accepts condition node without module (inline condition)" do
      condition = %{
        name: "check",
        type: "condition",
        params: %{"field" => "count", "op" => "gt", "value" => 0},
        index: 1
      }

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node, condition],
          edges: [@valid_edge]
        })

      assert changeset.valid?
    end
  end

  describe "edges validation" do
    test "rejects edge missing from field" do
      bad_edge = Map.delete(@valid_edge, :from)

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [bad_edge]
        })

      refute changeset.valid?
    end

    test "rejects edge missing to field" do
      bad_edge = Map.delete(@valid_edge, :to)

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [bad_edge]
        })

      refute changeset.valid?
    end
  end

  describe "nodes validation — archived status" do
    test "does not re-validate nodes when archiving an existing workflow" do
      existing = %Workflow{name: "W", status: "active", nodes: [], edges: [], settings: %{}}
      changeset = Workflow.changeset(existing, %{status: "archived"})
      assert changeset.valid?
    end
  end
end
