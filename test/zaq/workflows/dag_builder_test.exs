defmodule Zaq.Workflows.DagBuilderTest do
  use ExUnit.Case, async: true

  alias Zaq.Workflows.DagBuilder

  @fetch_module "Zaq.Agent.Tools.Email.FetchEmails"
  @emails_found_module "Zaq.Workflows.Conditions.EmailsFound"
  @no_emails_module "Zaq.Workflows.Conditions.NoEmails"
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
          "module" => @emails_found_module,
          "params" => %{},
          "index" => 1
        },
        %{
          "name" => "no_emails",
          "type" => "condition",
          "module" => @no_emails_module,
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
