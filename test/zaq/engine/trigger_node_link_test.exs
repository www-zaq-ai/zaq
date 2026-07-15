defmodule Zaq.Engine.TriggerNodeLinkTest do
  @moduledoc """
  Answers "why would the process running a trivial `Process.sleep/1` step ever
  die?" — a real crash needs a real cause; a plain sleep has none of its own.

  `Zaq.Engine.TriggerNode.fire/2` (the real production path every event/cron
  trigger goes through — see `Engine.EventRegistry.fire_or_register/3`) fans
  out via `Task.Supervisor.async_stream_nolink/4`, not bare
  `Task.async_stream/3`:

      Zaq.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        Workflows.list_workflows_for_trigger(event_name),
        &run_workflow(&1, event),
        ordered: false, on_timeout: :kill_task, timeout: :infinity
      )
      |> Stream.run()

  Bare `Task.async_stream/3` **links** every spawned task to whichever process
  called `fire/2`. That caller is itself a bare, unsupervised, unlinked task
  started by `Task.Supervisor.start_child/2` inside
  `Engine.EventRegistry.fire_or_register/3` — so the actual workflow-execution
  task's fate would be tied, via that link, to a completely unrelated wrapper
  process's survival. The `_nolink` variant means an in-flight run survives its
  dispatcher dying, while `fire/2` still only returns once every triggered run
  has actually finished (`Stream.run/1` consumes the whole stream) — many
  callers throughout the engine (nested/chained workflow triggers, HITL
  suspension flows) depend on that synchronous-completion contract, so `fire/2`
  is fire-and-forget only with respect to its *caller's* lifetime, not with
  respect to waiting for execution.

  These tests exercise the real `TriggerNode.fire/2` function (not a
  reimplementation) to prove the link is gone and has exactly this effect.
  """

  use Zaq.DataCase, async: false

  alias Zaq.Engine.TriggerNode
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Test.UseCaseFixtures
  alias Zaq.Event

  @sleep_module "Zaq.Agent.Tools.Workflow.Sleep"
  @ok_module "Zaq.Engine.Workflows.Test.OkAction"

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp triggered_sleep_workflow(event_name, duration_ms) do
    workflow_params = %{
      name: "TriggerLink #{System.unique_integer()}",
      status: "active",
      nodes: [
        %{name: "fast", type: "action", module: @ok_module, params: %{}, index: 0},
        %{
          name: "sleep_step",
          type: "action",
          module: @sleep_module,
          params: %{"duration_ms" => duration_ms},
          index: 1
        }
      ],
      edges: [%{from: "fast", to: "sleep_step"}]
    }

    {:ok, workflow} =
      UseCaseFixtures.create_workflow_with_trigger(workflow_params, %{
        event_name: event_name,
        trigger_type: "event"
      })

    workflow
  end

  # `Trigger.changeset/2` normalizes `event_name` by prefixing `"engine:"`
  # (unless it already contains a colon) so it matches `EventRegistry`'s
  # `"destination:name"` key convention. `TriggerNode.fire/2` is called with
  # that same normalized key in production (`EventRegistry.fire_or_register/3`
  # passes the already-derived key straight through) — so the test must too.
  defp normalized(event_name), do: "engine:#{event_name}"

  defp wait_until_running(run_id_finder, step_name, deadline_ms) do
    t0 = System.monotonic_time(:millisecond)
    do_wait_until_running(run_id_finder, step_name, t0, deadline_ms)
  end

  defp do_wait_until_running(run_id_finder, step_name, t0, deadline_ms) do
    case run_id_finder.() do
      nil ->
        if System.monotonic_time(:millisecond) - t0 > deadline_ms do
          {:error, :timeout, :no_run}
        else
          Process.sleep(10)
          do_wait_until_running(run_id_finder, step_name, t0, deadline_ms)
        end

      run_id ->
        row = run_id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == step_name))

        cond do
          match?(%{status: "running"}, row) ->
            {:ok, run_id}

          System.monotonic_time(:millisecond) - t0 > deadline_ms ->
            {:error, :timeout, row}

          true ->
            Process.sleep(10)
            do_wait_until_running(run_id_finder, step_name, t0, deadline_ms)
        end
    end
  end

  defp only_run_id_for(workflow_id) do
    fn ->
      case Workflows.list_runs(workflow_id) do
        [%{id: id}] -> id
        _ -> nil
      end
    end
  end

  # Propagates `$callers` (same as Task.start/1) so Mox/Sandbox ownership
  # resolves for the dispatcher and everything it spawns.
  defp spawn_dispatcher(fun) do
    callers = [self() | Process.get(:"$callers", [])]

    spawn(fn ->
      Process.put(:"$callers", callers)
      fun.()
    end)
  end

  test "killing TriggerNode.fire/2's caller must NOT kill the in-flight workflow run" do
    event_name = "trigger_link_test_#{System.unique_integer([:positive])}"
    workflow = triggered_sleep_workflow(event_name, 500)
    key = normalized(event_name)

    event = Event.new(%{}, :engine, name: key, trace_id: Ecto.UUID.generate())

    # This is exactly what `Engine.EventRegistry.fire_or_register/3` does in
    # production: `Task.Supervisor.start_child(Zaq.TaskSupervisor, fn -> TriggerNode.fire(...) end)`
    # — an unsupervised-for-restart, unlinked-to-EventRegistry wrapper task.
    dispatcher = spawn_dispatcher(fn -> TriggerNode.fire(key, event) end)
    ref = Process.monitor(dispatcher)

    assert {:ok, run_id} =
             wait_until_running(only_run_id_for(workflow.id), "sleep_step", 1_000)

    # Kill the DISPATCHER — not the workflow-execution task directly. In
    # production this stands in for the wrapper task dying for any reason
    # unrelated to the workflow: a `Zaq.TaskSupervisor` restart during a
    # deploy, a code reload, anything. A workflow run that is otherwise
    # healthy must survive that — its fate should never be coupled to an
    # unrelated dispatcher's.
    Process.exit(dispatcher, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dispatcher, :killed}, 1_000

    # sleep_step is only 500ms — give it well over a second to finish on its
    # own if it was never actually killed.
    Process.sleep(1_500)

    finished_step =
      run_id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "sleep_step"))

    finished_run = Workflows.get_run!(run_id)

    assert finished_step.status == "completed",
           "expected the workflow-execution task to survive its unrelated dispatcher dying " <>
             "(TriggerNode.fire/2 must not link workflow execution to its caller), " <>
             "got step status: #{inspect(finished_step.status)}"

    assert finished_run.status == "completed"
  end

  test "control: without killing the dispatcher, the same workflow completes normally" do
    event_name = "trigger_link_control_#{System.unique_integer([:positive])}"
    workflow = triggered_sleep_workflow(event_name, 200)
    key = normalized(event_name)

    event = Event.new(%{}, :engine, name: key, trace_id: Ecto.UUID.generate())

    dispatcher = spawn_dispatcher(fn -> TriggerNode.fire(key, event) end)
    ref = Process.monitor(dispatcher)

    # Let it run to completion undisturbed.
    assert_receive {:DOWN, ^ref, :process, ^dispatcher, :normal}, 2_000

    run_id = only_run_id_for(workflow.id).()
    refute is_nil(run_id)

    finished = Workflows.get_run!(run_id)
    assert finished.status == "completed"
  end
end
