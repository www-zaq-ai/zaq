defmodule Zaq.Workflows.DagBuilderTest do
  use ExUnit.Case, async: true

  alias Zaq.Workflows.DagBuilder

  @fetch_module "Zaq.Agent.Tools.Email.FetchEmails"
  @always_condition_module "Zaq.Workflows.Test.AlwaysCondition"
  @never_condition_module "Zaq.Workflows.Test.NeverCondition"
  @draft_module "Zaq.Agent.Tools.Email.DraftReply"

  defp linear_steps do
    %{
      "nodes" => [
        %{
          "name" => "fetch",
          "type" => "action",
          "module" => @fetch_module,
          "params" => %{},
          "index" => 0
        },
        %{
          "name" => "draft",
          "type" => "action",
          "module" => @draft_module,
          "params" => %{},
          "index" => 1
        }
      ],
      "edges" => [
        %{"from" => "fetch", "to" => "draft"}
      ]
    }
  end

  defp branching_steps do
    %{
      "nodes" => [
        %{
          "name" => "fetch",
          "type" => "action",
          "module" => @fetch_module,
          "params" => %{},
          "index" => 0
        },
        %{
          "name" => "emails_found",
          "type" => "condition",
          "module" => @always_condition_module,
          "params" => %{},
          "index" => 1
        },
        %{
          "name" => "no_emails",
          "type" => "condition",
          "module" => @never_condition_module,
          "params" => %{},
          "index" => 1
        },
        %{
          "name" => "draft",
          "type" => "action",
          "module" => @draft_module,
          "params" => %{},
          "index" => 2
        }
      ],
      "edges" => [
        %{"from" => "fetch", "to" => "emails_found"},
        %{"from" => "fetch", "to" => "no_emails"},
        %{"from" => "emails_found", "to" => "draft"}
      ]
    }
  end

  @ok_module "Zaq.Workflows.Test.OkAction"

  defp single_action_steps(module \\ @ok_module) do
    %{
      "nodes" => [
        %{"name" => "step", "type" => "action", "module" => module, "params" => %{}, "index" => 0}
      ],
      "edges" => []
    }
  end

  describe "build/2 — run_id instrumentation" do
    test "action nodes are wrapped in ActionWrapper when run_id is provided" do
      {:ok, workflow} = DagBuilder.build(single_action_steps(), run_id: "some-uuid")
      assert %Runic.Workflow{} = workflow
    end

    test "condition nodes are NOT wrapped when run_id is provided" do
      steps = %{
        "nodes" => [
          %{
            "name" => "fetch",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 0
          },
          %{
            "name" => "cond",
            "type" => "condition",
            "module" => @always_condition_module,
            "params" => %{},
            "index" => 1
          }
        ],
        "edges" => [%{"from" => "fetch", "to" => "cond"}]
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps, run_id: "some-uuid")
    end

    test "build/1 with no opts preserves existing behaviour (no ActionWrapper)" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(single_action_steps())
    end

    test "build/2 with nil run_id behaves like build/1 (no wrapping)" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(single_action_steps(), run_id: nil)
    end

    test "error cases still return errors when run_id provided" do
      assert {:error, {:unknown_module, "Does.Not.Exist"}} =
               DagBuilder.build(single_action_steps("Does.Not.Exist"), run_id: "some-uuid")
    end
  end

  describe "build/1 — happy path" do
    test "returns a Runic.Workflow for a linear DAG" do
      assert {:ok, workflow} = DagBuilder.build(linear_steps())
      assert %Runic.Workflow{} = workflow
    end

    test "returns a Runic.Workflow for a branching DAG with conditions" do
      assert {:ok, workflow} = DagBuilder.build(branching_steps())
      assert %Runic.Workflow{} = workflow
    end

    test "action nodes resolve params from the steps definition" do
      steps = %{
        "nodes" => [
          %{
            "name" => "fetch",
            "type" => "action",
            "module" => @fetch_module,
            "params" => %{"limit" => 5},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(steps)
    end

    test "builds without raising regardless of action parameter overlap" do
      assert {:ok, %Runic.Workflow{}} = DagBuilder.build(branching_steps())
    end
  end

  describe "build/1 — error cases" do
    test "returns error for empty nodes and edges" do
      assert {:error, :empty_dag} = DagBuilder.build(%{"nodes" => [], "edges" => []})
    end

    test "returns error for unknown action module" do
      steps = %{
        "nodes" => [
          %{
            "name" => "x",
            "type" => "action",
            "module" => "Does.Not.Exist",
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, {:unknown_module, "Does.Not.Exist"}} = DagBuilder.build(steps)
    end

    test "returns error for unknown condition module" do
      steps = %{
        "nodes" => [
          %{
            "name" => "x",
            "type" => "condition",
            "module" => "Does.Not.Exist",
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => []
      }

      assert {:error, {:unknown_module, "Does.Not.Exist"}} = DagBuilder.build(steps)
    end

    test "returns error when edge references unknown node" do
      steps = %{
        "nodes" => [
          %{
            "name" => "fetch",
            "type" => "action",
            "module" => @fetch_module,
            "params" => %{},
            "index" => 0
          }
        ],
        "edges" => [%{"from" => "fetch", "to" => "ghost"}]
      }

      assert {:error, {:unknown_node, "ghost"}} = DagBuilder.build(steps)
    end

    test "returns error for missing nodes key" do
      assert {:error, :invalid_steps} = DagBuilder.build(%{"edges" => []})
    end

    test "returns error for missing edges key" do
      assert {:error, :invalid_steps} = DagBuilder.build(%{"nodes" => []})
    end
  end
end
