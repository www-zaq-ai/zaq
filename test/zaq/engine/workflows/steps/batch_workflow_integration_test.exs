defmodule Zaq.Engine.Workflows.Steps.BatchWorkflowIntegrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Test.{CategorizeBySize, ListClients}
  alias Zaq.Engine.Workflows.WorkflowRunAgent
  @list_clients_module "Zaq.Engine.Workflows.Test.ListClients"
  @batch_module "Zaq.Agent.Tools.Workflow.Batch"
  @categorize_module "Zaq.Engine.Workflows.Test.CategorizeBySize"
  @sleep_module "Zaq.Engine.Workflows.Test.Sleep"
  @flatten_module "Zaq.Engine.Workflows.Test.FlattenClients"

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  # ── Step 1: ListClients ────────────────────────────────────────────────────

  describe "ListClients action" do
    test "returns exactly 10 clients with name, email, company, and size" do
      assert {:ok, %{clients: clients}} = ListClients.run(%{}, %{})

      assert length(clients) == 10

      for client <- clients do
        assert Map.has_key?(client, :name)
        assert Map.has_key?(client, :email)
        assert Map.has_key?(client, :company)
        assert is_integer(client.size) and client.size > 0
      end
    end
  end

  # ── Step 2: CategorizeBySize ───────────────────────────────────────────────

  describe "CategorizeBySize action" do
    test "categorizes small_business when size < 50" do
      assert {:ok, %{results: [result]}} =
               CategorizeBySize.run(%{items: [%{name: "Tiny", size: 8}]}, %{})

      assert result.category == "small_business"
    end

    test "categorizes medium when size is 50 to 500 inclusive" do
      for size <- [50, 250, 500] do
        assert {:ok, %{results: [result]}} =
                 CategorizeBySize.run(%{items: [%{name: "Mid", size: size}]}, %{})

        assert result.category == "medium"
      end
    end

    test "categorizes enterprise when size > 500" do
      assert {:ok, %{results: [result]}} =
               CategorizeBySize.run(%{items: [%{name: "Big", size: 501}]}, %{})

      assert result.category == "enterprise"
    end
  end

  # ── Full workflow definition (3 DAG nodes) ───────────────────────────────
  #
  # list_clients
  #   → batch  (batch_size: 2, strategy: skip_and_continue)
  #       process (inline): [categorize, sleep_200ms]  ← 5 × (categorize → sleep) runs
  #     → flatten_clients  (runs once after all 5 chunks, receives aggregated results)

  describe "workflow: list_clients → batch[categorize, sleep] → flatten" do
    defp four_node_workflow do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "Batch Pipeline #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{
              name: "list_clients",
              type: "action",
              module: @list_clients_module,
              params: %{},
              index: 0
            },
            %{
              name: "batch",
              type: "action",
              module: @batch_module,
              params: %{
                "batch_size" => 2,
                "strategy" => "skip_and_continue",
                "process" => [
                  %{
                    "name" => "categorize",
                    "type" => "action",
                    "module" => @categorize_module,
                    "params" => %{}
                  },
                  %{
                    "name" => "sleep_200ms",
                    "type" => "action",
                    "module" => @sleep_module,
                    "params" => %{"duration_ms" => 200}
                  }
                ]
              },
              index: 1
            },
            %{
              name: "flatten_clients",
              type: "action",
              module: @flatten_module,
              params: %{},
              index: 2
            }
          ],
          edges: [
            %{from: "list_clients", to: "batch", mapping: %{"items" => "clients"}},
            %{from: "batch", to: "flatten_clients", mapping: %{"results" => "results"}}
          ]
        })

      wf
    end

    test "workflow completes successfully" do
      wf = four_node_workflow()
      {:ok, run} = Workflows.create_run(wf, @source_event)

      assert {:ok, finished} = WorkflowRunAgent.execute(run)
      assert finished.status == "completed"
    end

    test "only list_clients, batch, and flatten_clients have step runs (scope nodes do not)" do
      wf = four_node_workflow()
      {:ok, run} = Workflows.create_run(wf, @source_event)

      {:ok, finished} = WorkflowRunAgent.execute(run)

      step_runs = Workflows.list_step_runs(finished.id)
      by_name = Map.new(step_runs, &{&1.step_name, &1})

      assert by_name["list_clients"].status == "completed"
      assert by_name["batch"].status == "completed"
      assert by_name["flatten_clients"].status == "completed"

      # Scope nodes are run inside Batch — they do not get their own step rows
      refute Map.has_key?(by_name, "categorize")
      refute Map.has_key?(by_name, "sleep_200ms")
    end

    test "batch produces 5 chunk results (batch_size: 2 over 10 clients)" do
      wf = four_node_workflow()
      {:ok, run} = Workflows.create_run(wf, @source_event)

      {:ok, finished} = WorkflowRunAgent.execute(run)

      step_runs = Workflows.list_step_runs(finished.id)
      batch_run = Enum.find(step_runs, &(&1.step_name == "batch"))

      assert length(batch_run.results["results"]) == 5
      assert batch_run.results["errors"] == []
    end

    test "flatten produces a flat list of 10 categorized clients" do
      wf = four_node_workflow()
      {:ok, run} = Workflows.create_run(wf, @source_event)

      {:ok, finished} = WorkflowRunAgent.execute(run)

      step_runs = Workflows.list_step_runs(finished.id)
      flatten_run = Enum.find(step_runs, &(&1.step_name == "flatten_clients"))

      clients = flatten_run.results["clients"]
      assert length(clients) == 10
      assert Enum.all?(clients, &Map.has_key?(&1, "category"))
    end

    test "category distribution survives the full pipeline: 3 small, 3 medium, 4 enterprise" do
      wf = four_node_workflow()
      {:ok, run} = Workflows.create_run(wf, @source_event)

      {:ok, finished} = WorkflowRunAgent.execute(run)

      step_runs = Workflows.list_step_runs(finished.id)
      flatten_run = Enum.find(step_runs, &(&1.step_name == "flatten_clients"))

      counts = Enum.frequencies_by(flatten_run.results["clients"], & &1["category"])

      assert counts["small_business"] == 3
      assert counts["medium"] == 3
      assert counts["enterprise"] == 4
    end
  end
end
