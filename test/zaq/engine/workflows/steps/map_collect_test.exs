defmodule Zaq.Engine.Workflows.Steps.MapCollectTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Steps.MapCollect

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  @valid_workflow_attrs %{
    name: "MapCollect Test Workflow",
    status: "draft",
    steps: %{"nodes" => [], "edges" => []}
  }

  @valid_source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  describe "run/2" do
    test "defaults non-list input to an empty result set" do
      assert {:ok, %{"results" => [], "errors" => [], "count" => 0}} =
               MapCollect.run(%{input: "not a list"}, %{})
    end

    test "returns input results when run_id is absent" do
      assert {:ok, %{"results" => [%{"ok" => true}], "errors" => [], "count" => 1}} =
               MapCollect.run(%{"input" => [%{"ok" => true}], "__map_prefix__" => "m/"}, nil)
    end

    test "returns input results when map prefix is absent" do
      run = create_run()

      assert {:ok, %{"results" => [%{"ok" => true}], "errors" => [], "count" => 1}} =
               MapCollect.run(%{input: [%{"ok" => true}]}, %{run_id: run.id})
    end

    test "collects failed fork rows sorted by fork index" do
      run = create_run()

      {:ok, _} =
        Workflows.create_step_run(run, %{
          step_name: "m/check[2]",
          step_index: 2,
          status: "failed_fatal",
          input: %{"email" => "second@example.com"},
          errors: %{"reason" => "condition_failed"}
        })

      {:ok, _} =
        Workflows.create_step_run(run, %{
          step_name: "m/check[0]",
          step_index: 0,
          status: "failed"
        })

      {:ok, _} =
        Workflows.create_step_run(run, %{
          step_name: "m/check",
          step_index: 3,
          status: "failed",
          input: %{"ignored" => true},
          errors: %{"reason" => "no fork index"}
        })

      {:ok, %{"results" => [%{"ok" => true}], "errors" => errors, "count" => 3}} =
        MapCollect.run(%{input: [%{"ok" => true}], __map_prefix__: "m/"}, %{run_id: run.id})

      assert errors == [
               %{"index" => 0, "item" => nil, "reason" => nil},
               %{
                 "index" => 2,
                 "item" => %{"email" => "second@example.com"},
                 "reason" => "condition_failed"
               }
             ]
    end
  end

  defp create_run do
    {:ok, workflow} = Workflows.create_workflow(@valid_workflow_attrs)
    {:ok, run} = Workflows.create_run(workflow, @valid_source_event)
    run
  end
end
