defmodule Zaq.Agent.Tools.Workflow.BatchTest do
  @moduledoc """
  Unit tests for the `Batch` translator: save-time `validate/1` and the invariant
  that `enrich/2` lowers a Batch node onto the internal `map` type (never exposing
  `map` as an authorable type).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.Tools.Workflow.{Batch, Iterate}

  @batch_module "Zaq.Agent.Tools.Workflow.Batch"
  @categorize_module "Zaq.Engine.Workflows.Test.CategorizeBySize"
  @sleep_module "Zaq.Engine.Workflows.Test.Sleep"
  @nonconforming_module "Zaq.Engine.Workflows.Test.NonConformingAction"
  @ok_module "Zaq.Engine.Workflows.Test.OkAction"

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
    test "allows an empty post-process pipeline and rejects a non-list pipeline" do
      process = %{"name" => "categorize", "type" => "action", "module" => @categorize_module}

      for translator <- [Batch, Iterate] do
        assert :ok =
                 translator.validate(batch_node(%{"process" => [process], "post_process" => []}))

        assert {:error, "post_process must be a list of nodes"} =
                 translator.validate(batch_node(%{"process" => [process], "post_process" => %{}}))
      end
    end

    property "both translators reject numeric post-process mapping sources" do
      check all(value <- integer(), max_runs: 20) do
        process = %{"name" => "categorize", "type" => "action", "module" => @categorize_module}
        first = Map.merge(process, %{"name" => "first", "mapping" => %{"value" => value}})

        second =
          Map.merge(process, %{"name" => "second", "mapping" => %{"value" => "categorize.result"}})

        last = Map.put(first, "name", "last")

        for translator <- [Batch, Iterate],
            {first_node, error_index} <- [
              {first, 0},
              {Map.put(first, "mapping", %{"value" => "categorize.result"}), 2}
            ] do
          node =
            batch_node(%{"process" => [process], "post_process" => [first_node, second, last]})

          assert {:error, message} = translator.validate(node)
          assert message =~ "post_process node #{error_index}"
          assert message =~ "mapping"
        end
      end
    end

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

    test "rejects an unsupported delivery mode" do
      node =
        batch_node(%{
          "delivery" => "stream",
          "process" => [
            %{
              "name" => "categorize",
              "type" => "action",
              "module" => @categorize_module,
              "params" => %{}
            }
          ]
        })

      assert {:error, ~s(delivery must be "item" or "list")} = Batch.validate(node)
    end

    test "rejects a process entry that cannot expose a batch field" do
      node = batch_node(%{"process" => [%{"name" => "missing_module"}]})

      assert {:error, :missing_process_pipeline} = Batch.validate(node)
    end

    test "accepts a valid Batch node without batch_size" do
      node =
        batch_node(%{
          "process" => [
            %{
              "name" => "categorize",
              "type" => "action",
              "module" => @categorize_module,
              "params" => %{}
            }
          ]
        })

      assert :ok = Batch.validate(node)
    end

    test "returns the batch-field detection error for resolvable modules without required fields" do
      node =
        batch_node(%{
          "process" => [
            %{
              "name" => "ok",
              "type" => "action",
              "module" => @ok_module,
              "params" => %{}
            }
          ]
        })

      assert {:error, {:no_batch_field, Zaq.Engine.Workflows.Test.OkAction}} =
               Batch.validate(node)
    end
  end
end
