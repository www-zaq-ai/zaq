defmodule Zaq.Engine.Workflows.WorkflowStepsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows.Step.Node
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

    test "rejects condition node type (removed — use edge conditions instead)" do
      condition_node = %{
        name: "check",
        type: "condition",
        params: %{"field" => "count", "op" => "gt", "value" => 0},
        index: 1
      }

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node, condition_node],
          edges: [@valid_edge]
        })

      refute changeset.valid?
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

    test "accepts edge with valid condition" do
      edge_with_cond = %{
        from: "fetch",
        to: "draft",
        condition: %{"field" => "count", "op" => "gt", "value" => 0}
      }

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [edge_with_cond]
        })

      assert changeset.valid?
    end

    test "rejects edge condition with unknown op" do
      bad_edge = %{
        from: "fetch",
        to: "draft",
        condition: %{"field" => "count", "op" => "bogus", "value" => 0}
      }

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [bad_edge]
        })

      refute changeset.valid?
    end

    test "accepts edge with valid mapping" do
      edge_with_map = %{
        from: "fetch",
        to: "draft",
        mapping: %{"email_count" => "count"}
      }

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [edge_with_map]
        })

      assert changeset.valid?
    end

    test "rejects edge mapping with non-string values" do
      bad_edge = %{
        from: "fetch",
        to: "draft",
        mapping: %{"target" => 123}
      }

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [bad_edge]
        })

      refute changeset.valid?
    end

    test "rejects edge condition that is not a map" do
      bad_edge = %{from: "fetch", to: "draft", condition: "not_a_map"}

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [bad_edge]
        })

      refute changeset.valid?
    end

    test "rejects edge condition missing op key" do
      bad_edge = %{from: "fetch", to: "draft", condition: %{"field" => "count"}}

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [bad_edge]
        })

      refute changeset.valid?
    end

    test "accepts edge with explicit nil mapping" do
      edge = %{from: "fetch", to: "draft", mapping: nil}

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [edge]
        })

      assert changeset.valid?
    end

    test "rejects edge mapping that is not a map" do
      bad_edge = %{from: "fetch", to: "draft", mapping: "not_a_map"}

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [bad_edge]
        })

      refute changeset.valid?
    end

    test "back-compat: plain from/to edge without condition or mapping remains valid" do
      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [@valid_edge]
        })

      assert changeset.valid?
    end

    test "Workflow.changeset round-trips edge with condition and mapping through embed" do
      edge = %{
        from: "fetch",
        to: "draft",
        condition: %{"field" => "gender", "op" => "eq", "value" => "male"},
        mapping: %{"person_name" => "name"}
      }

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: [edge]
        })

      assert changeset.valid?
      [embedded_edge] = get_change(changeset, :edges)

      assert get_field(embedded_edge, :condition) == %{
               "field" => "gender",
               "op" => "eq",
               "value" => "male"
             }

      assert get_change(embedded_edge, :mapping) == %{"person_name" => "name"}
    end
  end

  describe "Node.types/0" do
    test "returns the valid node type list" do
      assert Node.types() == ["action", "agent"]
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
