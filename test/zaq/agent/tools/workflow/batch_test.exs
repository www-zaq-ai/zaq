defmodule Zaq.Agent.Tools.Workflow.BatchTest do
  @moduledoc """
  Unit tests for the `Batch` translator: save-time `validate/1` and the invariant
  that `enrich/2` lowers a Batch node onto the internal `map` type (never exposing
  `map` as an authorable type).
  """
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.Batch

  @batch_module "Zaq.Agent.Tools.Workflow.Batch"
  @categorize_module "Zaq.Engine.Workflows.Test.CategorizeBySize"
  @sleep_module "Zaq.Engine.Workflows.Test.Sleep"
  @nonconforming_module "Zaq.Engine.Workflows.Test.NonConformingAction"

  defp batch_node(params) do
    %{
      "name" => "batch",
      "type" => "action",
      "module" => @batch_module,
      "index" => 1,
      "params" => params
    }
  end

  describe "enrich/2 — lowering to the internal map type" do
    test "rewrites a Batch node into a type: \"map\" node (never an authorable type)" do
      node =
        batch_node(%{
          "batch_size" => 2,
          "process" => [
            %{
              "name" => "categorize",
              "type" => "action",
              "module" => @categorize_module,
              "params" => %{}
            }
          ]
        })

      assert {:ok, lowered} = Batch.enrich(node, [])
      assert lowered["type"] == "map"
      assert lowered["name"] == "batch"
      assert lowered["params"]["over"] == "items"
      assert lowered["params"]["chunk_size"] == 2
    end
  end

  describe "validate/1" do
    test "accepts a Batch node whose process pipeline is contract-conforming" do
      node =
        batch_node(%{
          "batch_size" => 2,
          "process" => [
            %{
              "name" => "categorize",
              "type" => "action",
              "module" => @categorize_module,
              "params" => %{}
            },
            %{
              "name" => "sleep",
              "type" => "action",
              "module" => @sleep_module,
              "params" => %{"duration_ms" => 0}
            }
          ]
        })

      assert Batch.validate(node) == :ok
    end

    test "rejects a missing/empty process pipeline" do
      assert {:error, :missing_process_pipeline} = Batch.validate(batch_node(%{"process" => []}))
      assert {:error, :missing_process_pipeline} = Batch.validate(batch_node(%{}))
    end

    test "rejects a process node whose module does not satisfy the Action contract" do
      node =
        batch_node(%{
          "process" => [
            %{
              "name" => "categorize",
              "type" => "action",
              "module" => @categorize_module,
              "params" => %{}
            },
            %{
              "name" => "bad",
              "type" => "action",
              "module" => @nonconforming_module,
              "params" => %{}
            }
          ]
        })

      assert {:error, message} = Batch.validate(node)
      assert message =~ "process node 1"
      assert message =~ "Action contract"
    end

    test "rejects a non-positive batch_size" do
      for bad <- [0, -3, "5"] do
        node =
          batch_node(%{
            "batch_size" => bad,
            "process" => [
              %{
                "name" => "categorize",
                "type" => "action",
                "module" => @categorize_module,
                "params" => %{}
              }
            ]
          })

        assert {:error, "batch_size must be a positive integer"} = Batch.validate(node),
               "expected batch_size #{inspect(bad)} to be rejected"
      end
    end
  end
end
