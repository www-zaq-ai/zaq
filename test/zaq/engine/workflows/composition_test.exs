defmodule Zaq.Engine.Workflows.CompositionTest do
  @moduledoc """
  Unit tests for the workflow-in-workflow composition primitive
  (`Zaq.Engine.Workflows.Composition`). The splice is pure over snapshots; the
  referenced workflow's snapshot is supplied by an injected `resolver` fun, so
  these tests need no database.

  See `docs/exec-plans/active/pr-430-workflow-composition-primitive.md`.
  """
  use ExUnit.Case, async: true

  # local `node/1` helper shadows `Kernel.node/1`
  import Kernel, except: [node: 1]

  alias Zaq.Engine.Workflows.Composition

  @ok "Zaq.Engine.Workflows.Test.OkAction"

  defp node(name, opts \\ []) do
    %{
      "name" => name,
      "type" => Keyword.get(opts, :type, "action"),
      "module" => Keyword.get(opts, :module, @ok),
      "params" => Keyword.get(opts, :params, %{}),
      "index" => Keyword.get(opts, :index, 0)
    }
  end

  defp ref(name, id),
    do: node(name, type: "workflow", module: nil, params: %{"workflow_ref" => id})

  # sub-workflow #1: D -> E -> F (single root D, single leaf F)
  defp sub_snapshot do
    %{
      "nodes" => [node("D"), node("E"), node("F")],
      "edges" => [%{"from" => "D", "to" => "E"}, %{"from" => "E", "to" => "F"}]
    }
  end

  defp resolver, do: fn "wf1" -> {:ok, sub_snapshot()} end

  describe "expand/2 — single reference" do
    test "inlines the referenced workflow, namespaced, rewiring the seam" do
      parent = %{
        "nodes" => [node("A"), node("B"), ref("call1", "wf1"), node("C")],
        "edges" => [
          %{"from" => "A", "to" => "B"},
          %{"from" => "B", "to" => "call1"},
          %{"from" => "call1", "to" => "C"}
        ]
      }

      assert {:ok, flat} = Composition.expand(parent, resolver())

      names = Enum.map(flat["nodes"], & &1["name"])
      assert names == ["A", "B", "call1/D", "call1/E", "call1/F", "C"]
      refute "call1" in names

      # seam: B -> entry(D), exit(F) -> C
      assert %{"from" => "B", "to" => "call1/D"} in flat["edges"]
      assert %{"from" => "call1/F", "to" => "C"} in flat["edges"]
      # internal edges preserved, namespaced
      assert %{"from" => "call1/D", "to" => "call1/E"} in flat["edges"]
      assert %{"from" => "call1/E", "to" => "call1/F"} in flat["edges"]
      # the original referencing edges are gone
      refute %{"from" => "B", "to" => "call1"} in flat["edges"]
      refute %{"from" => "call1", "to" => "C"} in flat["edges"]
    end

    test "preserves edge condition/mapping at the seam (D6 passthrough)" do
      parent = %{
        "nodes" => [node("B"), ref("call1", "wf1"), node("C")],
        "edges" => [
          %{"from" => "B", "to" => "call1", "mapping" => %{"x" => "y"}},
          %{"from" => "call1", "to" => "C", "condition" => "ok"}
        ]
      }

      assert {:ok, flat} = Composition.expand(parent, resolver())

      assert %{"from" => "B", "to" => "call1/D", "mapping" => %{"x" => "y"}} in flat["edges"]
      assert %{"from" => "call1/F", "to" => "C", "condition" => "ok"} in flat["edges"]
    end

    test "leaves a snapshot with no references untouched (indexes already sequential)" do
      parent = %{
        "nodes" => [node("A", index: 0), node("B", index: 1)],
        "edges" => [%{"from" => "A", "to" => "B"}]
      }

      assert {:ok, ^parent} = Composition.expand(parent, resolver())
    end
  end

  describe "expand/2 — entry/exit constraint (D3)" do
    test "rejects a referenced workflow with more than one leaf" do
      diamond = fn "wf1" ->
        {:ok,
         %{
           "nodes" => [node("D"), node("E"), node("F")],
           "edges" => [%{"from" => "D", "to" => "E"}, %{"from" => "D", "to" => "F"}]
         }}
      end

      parent = %{"nodes" => [ref("call1", "wf1")], "edges" => []}
      assert {:error, {:multi_entry_exit, _roots, _leaves}} = Composition.expand(parent, diamond)
    end

    test "rejects a referenced workflow with more than one root" do
      forked = fn "wf1" ->
        {:ok,
         %{
           "nodes" => [node("D"), node("E"), node("F")],
           "edges" => [%{"from" => "D", "to" => "F"}, %{"from" => "E", "to" => "F"}]
         }}
      end

      parent = %{"nodes" => [ref("call1", "wf1")], "edges" => []}
      assert {:error, {:multi_entry_exit, _roots, _leaves}} = Composition.expand(parent, forked)
    end
  end

  describe "expand/2 — nested references" do
    test "flattens a reference that itself references another workflow" do
      # wf_outer: X -> (ref wf_inner) ; wf_inner: D -> E
      res = fn
        "wf_outer" ->
          {:ok,
           %{
             "nodes" => [node("X"), ref("inner", "wf_inner")],
             "edges" => [%{"from" => "X", "to" => "inner"}]
           }}

        "wf_inner" ->
          {:ok,
           %{
             "nodes" => [node("D"), node("E")],
             "edges" => [%{"from" => "D", "to" => "E"}]
           }}
      end

      parent = %{"nodes" => [ref("call1", "wf_outer")], "edges" => []}

      assert {:ok, flat} = Composition.expand(parent, res)
      names = Enum.map(flat["nodes"], & &1["name"])
      assert names == ["call1/X", "call1/inner/D", "call1/inner/E"]
    end
  end

  describe "validate/2 (D5)" do
    test "flags a direct referenced-workflow cycle" do
      res = fn
        "wf1" -> {:ok, %{"nodes" => [ref("c", "wf2")], "edges" => []}}
        "wf2" -> {:ok, %{"nodes" => [ref("c", "wf1")], "edges" => []}}
      end

      parent = %{"nodes" => [ref("call1", "wf1")], "edges" => []}
      assert {:error, {:workflow_cycle, _id}} = Composition.validate(parent, res)
    end

    test "flags a cycle introduced across branches after expansion" do
      # A fans out to B and C->D, and D loops back to A — the flattened graph
      # must stay acyclic (the @jat10 branch case).
      parent = %{
        "nodes" => [node("A"), node("B"), node("C"), node("D")],
        "edges" => [
          %{"from" => "A", "to" => "B"},
          %{"from" => "A", "to" => "C"},
          %{"from" => "C", "to" => "D"},
          %{"from" => "D", "to" => "A"}
        ]
      }

      assert {:error, {:workflow_not_acyclic, _}} =
               Composition.validate(parent, fn _ -> {:error, :none} end)
    end

    test "passes a valid acyclic composition" do
      parent = %{
        "nodes" => [node("A"), ref("call1", "wf1"), node("C")],
        "edges" => [%{"from" => "A", "to" => "call1"}, %{"from" => "call1", "to" => "C"}]
      }

      assert :ok = Composition.validate(parent, resolver())
    end
  end
end
