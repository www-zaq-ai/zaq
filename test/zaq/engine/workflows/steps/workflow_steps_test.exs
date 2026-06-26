defmodule Zaq.Engine.Workflows.WorkflowStepsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows.DagBuilder
  alias Zaq.Engine.Workflows.Step.Node
  alias Zaq.Engine.Workflows.Workflow

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Engine.Workflows.Test.InboxWithResults",
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

  describe "nodes validation — module contract (Task 13)" do
    test "rejects an action node whose module does not resolve" do
      bad_node = %{@valid_node | module: "Zaq.Does.Not.Exist"}

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [bad_node],
          edges: []
        })

      refute changeset.valid?
      assert changeset.changes.nodes |> hd() |> Map.fetch!(:errors) |> Keyword.has_key?(:module)
    end

    test "rejects an action node whose module does not satisfy the Action contract" do
      bad_node = %{@valid_node | module: "Zaq.Engine.Workflows.Test.NonConformingAction"}

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [bad_node],
          edges: []
        })

      refute changeset.valid?
      assert changeset.changes.nodes |> hd() |> Map.fetch!(:errors) |> Keyword.has_key?(:module)
    end

    test "accepts an action node whose module resolves and conforms" do
      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node],
          edges: []
        })

      assert changeset.valid?
    end

    test "rejects a Batch node whose process body contains a non-conforming module" do
      bad_process = [
        %{
          "name" => "lookup",
          "type" => "action",
          "module" => "Zaq.Engine.Workflows.Test.NonConformingAction",
          "params" => %{}
        }
      ]

      bad_node = %{
        name: "enrich_each",
        type: "action",
        module: "Zaq.Agent.Tools.Workflow.Batch",
        params: %{"process" => bad_process},
        index: 1
      }

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node, bad_node],
          edges: [%{from: "fetch", to: "enrich_each"}]
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

  describe "nodes validation — workflow reference nodes" do
    @workflow_ref_node %{
      name: "call_sub",
      type: "workflow",
      params: %{"workflow_ref" => "00000000-0000-0000-0000-000000000001"},
      index: 1
    }

    test "accepts a workflow node carrying a workflow_ref (no module needed)" do
      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node, @workflow_ref_node],
          edges: [%{from: "fetch", to: "call_sub"}]
        })

      assert changeset.valid?
    end

    test "rejects a workflow node missing workflow_ref" do
      bad_node = %{@workflow_ref_node | params: %{}}

      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node, bad_node],
          edges: [%{from: "fetch", to: "call_sub"}]
        })

      refute changeset.valid?
    end
  end

  describe "nodes validation — map is not an authorable type" do
    # `map` is an internal lowering target produced by a translator's `enrich/2`
    # (the `Batch` action) — never authored directly. Iteration validation now
    # lives in `Batch.validate/1` (see the Batch tool test).
    @map_node %{
      name: "enrich_each",
      type: "map",
      params: %{
        "over" => "leads",
        "body" => [
          %{
            "name" => "lookup",
            "type" => "action",
            "module" => "Zaq.Engine.Workflows.Test.InboxWithResults",
            "params" => %{}
          }
        ]
      },
      index: 1
    }

    test "rejects a directly-authored map node" do
      changeset =
        Workflow.changeset(%Workflow{}, %{
          name: "W",
          status: "active",
          nodes: [@valid_node, @map_node],
          edges: [%{from: "fetch", to: "enrich_each"}]
        })

      refute changeset.valid?

      node_errors =
        changeset
        |> Ecto.Changeset.get_change(:nodes)
        |> Enum.flat_map(& &1.errors)

      assert Enum.any?(node_errors, fn {field, _} -> field == :type end)
    end
  end

  describe "Node.types/0" do
    test "returns the valid (authorable) node type list — map is internal-only" do
      assert Node.types() == ["action", "agent", "workflow"]
    end
  end

  describe "nodes validation — reserved sentinel names (issue #508)" do
    test "rejects a node named \"start\"" do
      changeset = Node.changeset(%Node{}, %{@valid_node | name: "start"})

      refute changeset.valid?
      assert changeset.errors[:name]
    end

    test "rejects a node named \"start\" case-insensitively / with surrounding space" do
      changeset = Node.changeset(%Node{}, %{@valid_node | name: "  Start "})

      refute changeset.valid?
      assert changeset.errors[:name]
    end

    test "accepts non-reserved names" do
      changeset = Node.changeset(%Node{}, %{@valid_node | name: "kickoff"})
      assert changeset.valid?
    end

    test "reserved_node_names/0 agrees with DagBuilder.start_sentinel/0" do
      assert DagBuilder.start_sentinel() in Node.reserved_node_names()
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
