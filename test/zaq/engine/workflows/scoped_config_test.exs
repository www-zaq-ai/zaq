defmodule Zaq.Engine.Workflows.ScopedConfigTest do
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Engine.TriggerNode
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.DateOperand
  alias Zaq.Event

  defmodule FirstConfig do
    def get(:zaq, :workflow_config_probe, _default), do: "first"
    def get(:zaq, DateOperand, _default), do: [clock: fn -> ~U[2000-01-01 12:00:00Z] end]
  end

  defmodule SecondConfig do
    def get(:zaq, :workflow_config_probe, _default), do: "second"
    def get(:zaq, DateOperand, _default), do: [clock: fn -> ~U[2000-01-02 12:00:00Z] end]
  end

  defmodule Probe do
    use Jido.Action,
      name: "workflow_config_probe",
      schema: [input: [type: :any, required: true]],
      output_schema: [value: [type: :string, required: true]]

    @behaviour Zaq.Engine.Workflows.Action

    @impl true
    def run(_params, context) do
      value = Zaq.Config.get(:zaq, :workflow_config_probe, "default", config: context[:config])
      {:ok, %{value: value}}
    end

    @impl Zaq.Engine.Workflows.Action
    def on_success(result, _context), do: {:ok, result}

    @impl Zaq.Engine.Workflows.Action
    def on_failure(_error, _context), do: :ok
  end

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)
    :ok
  end

  test "concurrent runs of the same workflow keep separate providers and retain the default" do
    workflow = create_workflow([probe_node()])

    configs = [
      {[config: FirstConfig], "first"},
      {[config: SecondConfig], "second"},
      {[], "default"}
    ]

    runs =
      Enum.map(configs, fn {opts, value} ->
        {:ok, run} = Workflows.create_run(workflow, source_event())
        {run, opts, value}
      end)

    tasks =
      Enum.map(runs, fn {run, opts, value} ->
        Task.async(fn ->
          receive do
            :start -> {Workflows.start_run(run, opts), value}
          end
        end)
      end)

    Enum.each(tasks, &send(&1.pid, :start))

    for {result, value} <- Task.await_many(tasks) do
      assert {:ok, %{id: run_id, status: "completed"}} = result
      assert [%{results: %{"value" => ^value}}] = Workflows.list_step_runs(run_id)
    end
  end

  test "batch and iterate actions read the run's provider" do
    for module <- [Zaq.Agent.Tools.Workflow.Batch, Zaq.Agent.Tools.Workflow.Iterate] do
      workflow =
        create_workflow([
          %{
            name: "mapped",
            type: "action",
            module: inspect(module),
            index: 0,
            params: %{
              "delivery" => "item",
              "process" => [
                %{
                  "name" => "probe",
                  "type" => "action",
                  "module" => inspect(Probe),
                  "params" => %{}
                }
              ]
            }
          }
        ])

      {:ok, run} = Workflows.create_run(workflow, source_event(%{"items" => [1, 2]}))
      assert {:ok, %{status: "completed"}} = Workflows.start_run(run, config: FirstConfig)

      assert [%{results: %{"value" => "first"}}, %{results: %{"value" => "first"}}] =
               Enum.filter(Workflows.list_step_runs(run.id), fn step ->
                 String.starts_with?(step.step_name, "mapped/probe[")
               end)
    end
  end

  test "date edge conditions read the scoped clock" do
    workflow =
      create_workflow([probe_node()], [
        %{
          from: "start",
          to: "probe",
          condition: %{field: "date", op: "eq", value: "today", type: "date"}
        }
      ])

    for {config, status} <- [{FirstConfig, "completed"}, {SecondConfig, "incomplete"}] do
      {:ok, run} = Workflows.create_run(workflow, source_event(%{"date" => "2000-01-01"}))
      assert {:ok, %{status: ^status}} = Workflows.start_run(run, config: config)
    end
  end

  test "triggered runs use the event's provider without storing it in the source event" do
    workflow = create_workflow([probe_node()])
    trigger_name = "scoped_config_trigger"
    {:ok, trigger} = Workflows.create_trigger(%{event_name: trigger_name, enabled: true})
    {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)

    event = Event.new(%{}, :engine, opts: [config: FirstConfig])

    assert :ok = TriggerNode.fire("engine:" <> trigger_name, event)
    assert [%{id: run_id, status: "completed"}] = Workflows.list_runs(workflow.id)
    assert [%{results: %{"value" => "first"}}] = Workflows.list_step_runs(run_id)
    assert Workflows.get_run!(run_id).source_event.opts == []
  end

  test "resuming a reloaded run passes the scoped clock to a condition action" do
    workflow =
      create_workflow([
        %{
          name: "check_date",
          type: "action",
          module: "Zaq.Agent.Tools.Workflow.Condition",
          index: 0,
          params: %{
            "conditions" => [%{"key" => "date", "value" => "today", "type" => "date"}]
          }
        }
      ])

    {:ok, run} = Workflows.create_run(workflow, source_event(%{"date" => "2000-01-01"}))
    {:ok, _} = Workflows.update_run(run, %{status: "paused"})
    reloaded_run = Workflows.get_run!(run.id)

    assert {:ok, %{status: "completed"}} = Workflows.resume_run(reloaded_run, config: FirstConfig)
    assert [%{results: %{"passed" => true}}] = Workflows.list_step_runs(run.id)
  end

  defp probe_node do
    %{name: "probe", type: "action", module: inspect(Probe), params: %{}, index: 0}
  end

  defp create_workflow(nodes, edges \\ []) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Scoped workflow config #{System.unique_integer([:positive])}",
        status: "active",
        nodes: nodes,
        edges: edges
      })

    workflow
  end

  defp source_event(input \\ %{}) do
    %{
      "assigns" => %{"trigger_type" => "manual", "input" => input},
      "trace_id" => Ecto.UUID.generate()
    }
  end
end
