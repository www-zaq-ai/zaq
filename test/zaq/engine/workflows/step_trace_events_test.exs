defmodule Zaq.Engine.Workflows.StepTraceEventsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Jido.AI.Runtime.Event
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Step.Run, as: StepRun

  setup do
    owner = self()

    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(owner, {:workflow_broadcast, event.request})
      event
    end)

    {:ok, workflow} =
      Workflows.create_workflow(%{name: "Trace storage", steps: %{"nodes" => [], "edges" => []}})

    {:ok, run} = Workflows.create_run(workflow, %{"request" => nil, "assigns" => %{}})
    {:ok, step} = Workflows.create_step_run(run, %{step_name: "trace", step_index: 0})
    %{run: run, step: step}
  end

  defp event(step, attrs \\ %{}) do
    root = "workflow_step:#{step.id}"
    segment = Ecto.UUID.generate()

    Event.new(
      Map.merge(
        %{
          seq: 0,
          iteration: 0,
          request_id: step.workflow_run_id,
          run_id: step.workflow_run_id,
          kind: :tool_completed,
          tool_call_id: "zaq.#{Base.url_encode64(root, padding: false)}.#{segment}",
          tool_name: "child",
          data: %{
            origin: "zaq_action",
            invocation_path: [root, segment],
            parent_id: root,
            outcome: "succeeded",
            result: {:ok, %{password: "PRIVATE"}, []}
          }
        },
        attrs
      )
    )
  end

  test "append is idempotent and lifecycle updates return fresh trace evidence", %{
    step: step,
    run: run
  } do
    assert step.trace_events == []
    event = event(step)
    assert {:ok, recorded} = Workflows.record_step_event(step.id, event)
    assert {:ok, replayed} = Workflows.record_step_event(step.id, event)
    assert replayed.trace_events == recorded.trace_events
    assert length(recorded.trace_events) == 1
    assert recorded.status == "running"
    refute Jason.encode!(recorded.trace_events) =~ "PRIVATE"

    assert {:ok, completed} =
             Workflows.complete_step_run(step, %{value: 42}, [%{event: "step_completed"}])

    assert completed.trace_events == recorded.trace_events
    assert completed.status == "completed"

    assert_receive {:workflow_broadcast,
                    {:broadcast, _, {:step_updated, %{status: "completed", trace_events: events}}}}

    assert events == recorded.trace_events
    assert [%{"event" => "step_completed"}] = hd(Workflows.list_step_runs(run.id)).logs
    assert {:ok, late} = Workflows.record_step_event(step.id, event(step))
    assert late.status == "completed"
    assert late.results == %{"value" => 42}
    assert length(late.trace_events) == 2
  end

  test "wrong-root, inconsistent identity, and unsupported lifecycle events are rejected", %{
    step: step
  } do
    other = %{step | id: Ecto.UUID.generate()}
    assert {:error, :invalid_trace_event} = Workflows.record_step_event(step.id, event(other))

    assert {:error, :invalid_trace_event} =
             Workflows.record_step_event(step.id, event(step, %{kind: :request_completed}))

    assert {:error, :invalid_trace_event} =
             Workflows.record_step_event(step.id, event(step, %{tool_call_id: "wrong"}))

    assert {:error, :invalid_trace_event} = Workflows.record_step_event(step.id, %{})
    assert Repo.get!(StepRun, step.id).trace_events == []
  end

  property "duplicate event IDs never append again and leave business fields untouched", %{
    step: step
  } do
    check all(repetitions <- integer(1..5), max_runs: 10) do
      before = Repo.get!(StepRun, step.id)
      event = event(step)
      for _ <- 1..repetitions, do: assert({:ok, _} = Workflows.record_step_event(step.id, event))
      after_step = Repo.get!(StepRun, step.id)
      assert length(after_step.trace_events) == length(before.trace_events) + 1

      assert Map.take(after_step, [:status, :results, :errors, :logs, :started_at, :finished_at]) ==
               Map.take(before, [:status, :results, :errors, :logs, :started_at, :finished_at])
    end
  end
end

defmodule Zaq.Engine.Workflows.StepTraceEventsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Mox
  alias Ecto.Adapters.SQL.Sandbox
  alias Jido.AI.Runtime.Event
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Engine.Workflows.{Workflow, WorkflowRun}
  alias Zaq.Repo

  setup do
    Zaq.DataCase.isolate_event_registry()
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)

    {workflow, run, step} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, workflow} =
          Workflows.create_workflow(%{
            name: "Concurrent traces #{Ecto.UUID.generate()}",
            steps: %{"nodes" => [], "edges" => []}
          })

        {:ok, run} = Workflows.create_run(workflow, %{"request" => nil, "assigns" => %{}})
        {:ok, step} = Workflows.create_step_run(run, %{step_name: "trace", step_index: 0})
        {workflow, run, step}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from s in StepRun, where: s.workflow_run_id == ^run.id)
        Repo.delete_all(from r in WorkflowRun, where: r.id == ^run.id)
        Repo.delete_all(from w in Workflow, where: w.id == ^workflow.id)
      end)
    end)

    %{step: step, run: run}
  end

  test "separate connections serialize simultaneous appends and preserve lifecycle writes", %{
    step: step,
    run: run
  } do
    root = "workflow_step:#{step.id}"

    events =
      for _ <- 1..2 do
        segment = Ecto.UUID.generate()

        Event.new(%{
          kind: :tool_started,
          seq: 0,
          iteration: 0,
          request_id: run.id,
          run_id: run.id,
          tool_call_id: "zaq.#{Base.url_encode64(root, padding: false)}.#{segment}",
          data: %{origin: "zaq_action", invocation_path: [root, segment], parent_id: root}
        })
      end

    owner = self()

    first =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          handler = {__MODULE__, make_ref()}

          :telemetry.attach(handler, [:zaq, :repo, :query], &__MODULE__.hold_lock/4, %{
            owner: self(),
            parent: owner
          })

          try do
            Workflows.record_step_event(step.id, hd(events))
          after
            :telemetry.detach(handler)
          end
        end)
      end)

    try do
      assert_receive {:trace_row_locked, locked}, 5_000

      second =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Workflows.record_step_event(step.id, List.last(events))
          end)
        end)

      terminal =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Workflows.complete_step_run(step, %{value: 42})
          end)
        end)

      error =
        assert_raise Postgrex.Error, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.one!(from s in StepRun, where: s.id == ^step.id, lock: "FOR UPDATE NOWAIT")
            end)
          end)
        end

      assert error.postgres.code == :lock_not_available
      send(locked, :release_trace_lock)
      assert {:ok, _} = Task.await(first, 5_000)
      assert {:ok, _} = Task.await(second, 5_000)
      assert {:ok, %{status: "completed"}} = Task.await(terminal, 5_000)

      Sandbox.unboxed_run(Repo, fn ->
        completed = Repo.get!(StepRun, step.id)
        assert completed.status == "completed"
        assert length(completed.trace_events) == 2

        assert Enum.sort(Enum.map(completed.trace_events, & &1["id"])) ==
                 Enum.sort(Enum.map(events, & &1.id))
      end)
    after
      send(first.pid, :release_trace_lock)
      Task.shutdown(first)
    end
  end

  @doc "Synchronizes a real locked transaction through Repo query telemetry."
  def hold_lock(_, _, %{query: query}, %{owner: owner, parent: parent}) do
    if self() == owner and String.contains?(query, "FOR UPDATE") do
      send(parent, {:trace_row_locked, self()})

      receive do
        :release_trace_lock -> :ok
      after
        10_000 -> raise "Trace lock barrier not released"
      end
    end
  end
end
