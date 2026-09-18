defmodule Zaq.Engine.Workflows.SuspensionDriverTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.{PendingApproval, Step, StepRunner}
  alias Zaq.Engine.Workflows.Steps.HumanInTheLoop
  alias Zaq.Engine.Workflows.Workflow
  alias Zaq.Repo

  @hitl "Zaq.Engine.Workflows.Steps.HumanInTheLoop"
  @ok "Zaq.Engine.Workflows.Test.OkAction"
  @event %{request: nil, assigns: %{trigger_type: "manual"}}

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp workflow(nodes, edges) do
    # Exercise the internal map primitive through the real preparation boundary.
    Repo.insert!(%Workflow{
      name: "suspension-#{System.unique_integer([:positive])}",
      status: "active",
      nodes: Enum.map(nodes, &struct(Step.Node, &1)),
      edges: Enum.map(edges, &struct(Step.Edge, &1))
    })
  end

  defp action(name, mod), do: %{name: name, type: "action", module: mod, params: %{}, index: 0}

  property "generated sibling branches suspend before applying control and replay exactly once" do
    check all(branches <- integer(1..4), depth <- integer(1..3), max_runs: 8) do
      nodes =
        for branch <- 1..branches, level <- 0..depth do
          action("branch_#{branch}_#{level}", if(level == 0, do: @hitl, else: @ok))
        end

      edges =
        for branch <- 1..branches, level <- 1..depth do
          %{from: "branch_#{branch}_#{level - 1}", to: "branch_#{branch}_#{level}"}
        end

      wf = workflow(nodes, edges)
      driver = Task.async(fn -> Workflows.create_and_start_run(wf, @event) end)
      assert {:ok, run} = Task.await(driver)
      refute Process.alive?(driver.pid)
      assert run.status == "waiting"
      assert [first] = Workflows.list_step_runs(run.id)
      assert first.status == "waiting"
      assert first.results == nil

      finished =
        Enum.reduce(1..branches, run, fn _, current ->
          approval = Workflows.get_pending_approval(current.id)
          assert approval != nil

          assert {:ok, next} =
                   Workflows.approve_step(Workflows.get_run!(current.id), approval, %{}, nil)

          next
        end)

      assert finished.status == "completed"
      rows = Workflows.list_step_runs(run.id)
      assert length(rows) == branches * (depth + 1)
      assert Enum.all?(rows, &(&1.status == "completed"))
      assert Enum.uniq_by(rows, & &1.step_name) == rows
    end
  end

  test "the first pending sibling stops the pass before any other sibling or downstream work" do
    wf =
      workflow(
        [action("a", @hitl), action("b", @hitl), action("tail", @ok)],
        [%{from: "a", to: "tail"}, %{from: "b", to: "tail"}]
      )

    assert {:ok, waiting} = Workflows.create_and_start_run(wf, @event)
    assert waiting.status == "waiting"
    assert [row] = Workflows.list_step_runs(waiting.id)
    assert row.step_name in ["a", "b"]
    assert row.status == "waiting"
    assert row.results == nil
    approval = Workflows.get_pending_approval(waiting.id)
    assert approval.step_name == row.step_name
  end

  test "interruption between approval creation and waiting reuses both approval and cursor" do
    wf = workflow([action("review", @hitl)], [])
    {:ok, run} = Workflows.create_run(wf, @event)

    {:ok, cursor} =
      Workflows.create_step_run(run, %{step_name: "review", step_index: 0, status: "running"})

    {:ok, approval} =
      Workflows.ensure_pending_approval(%{workflow_run_id: run.id, step_name: "review"})

    params = %{wrapped_module: HumanInTheLoop, run_id: run.id, step_name: "review", step_index: 0}
    opts = [timeout: 0, max_retries: 0, backoff: 0, telemetry: :silent]

    for _ <- 1..2 do
      assert {:ok, %{}, workflow_control: %PendingApproval{} = control} =
               Jido.Exec.run(StepRunner, params, %{}, opts)

      assert control.approval_token == approval.approval_token
      assert [row] = Workflows.list_step_runs(run.id)
      assert row.id == cursor.id
      assert row.status == "waiting"
      assert row.results == nil
    end
  end

  test "real inner Jido validates the empty HITL output and reuses its approval" do
    wf = workflow([action("review", @hitl)], [])
    {:ok, run} = Workflows.create_run(wf, @event)
    context = %{run_id: run.id, step_name: "review"}
    opts = [timeout: 0, max_retries: 0, backoff: 0, telemetry: :silent]

    assert {:ok, %{}, workflow_control: control} =
             Jido.Exec.run(HumanInTheLoop, %{}, context, opts)

    assert {:ok, %{}, workflow_control: ^control} =
             Jido.Exec.run(HumanInTheLoop, %{}, context, opts)

    assert control.step_name == "review"
    assert Workflows.get_step_approval(run.id, "review").approval_token == control.approval_token
  end

  test "stale approval decisions and approvals for another run cannot mutate lifecycle state" do
    wf = workflow([action("review", @hitl)], [])
    {:ok, first} = Workflows.create_and_start_run(wf, @event)
    {:ok, second} = Workflows.create_and_start_run(wf, @event)
    approval = Workflows.get_pending_approval(first.id)
    assert {:error, :approval_run_mismatch} = Workflows.approve_step(second, approval, %{}, nil)
    assert Workflows.get_step_approval(first.id, "review").status == "pending"

    assert {:ok, done} = Workflows.approve_step(first, approval, %{}, nil)
    assert done.status == "completed"
    assert {:error, :not_waiting} = Workflows.reject_step(first, approval, "stale decision", nil)
    assert Workflows.get_run!(first.id).status == "completed"
    assert Workflows.get_step_approval(first.id, "review").status == "approved"
  end

  test "cached isolated failure replays its fork identity without executing again" do
    wf = workflow([action("emit", @ok)], [])
    {:ok, run} = Workflows.create_run(wf, @event)

    {:ok, row} =
      Workflows.create_step_run(run, %{step_name: "m/failed[3]", step_index: 0, status: "running"})

    {:ok, _} =
      Workflows.fail_step_run(row, %{reason: "already tried"}, [], status: "failed_fatal")

    params = %{
      wrapped_module: HumanInTheLoop,
      run_id: run.id,
      step_name: "m/failed",
      step_index: 0,
      __map_index__: 3,
      __map_strategy__: "retry"
    }

    assert {:ok, %{"__map_index__" => 3, "__map_error__" => true}} = StepRunner.run(params, %{})
    assert [replayed] = Workflows.list_step_runs(run.id)
    assert replayed.id == row.id
    assert Workflows.get_step_approval(run.id, "m/failed[3]") == nil
  end

  for strategy <- ["skip_and_continue", "retry", "fail_workflow"] do
    test "map #{strategy} suspends before later body steps, forks and collection, then resumes" do
      wf =
        workflow(
          [
            action("emit", "Zaq.Engine.Workflows.Test.EmitItems"),
            %{
              name: "m",
              type: "map",
              index: 1,
              params: %{
                "over" => "items",
                "strategy" => unquote(strategy),
                "body" => [
                  %{"name" => "review", "type" => "action", "module" => @hitl},
                  %{"name" => "tail", "type" => "action", "module" => @ok}
                ]
              }
            }
          ],
          [%{from: "emit", to: "m"}]
        )

      assert {:ok, waiting} = Workflows.create_and_start_run(wf, @event)
      assert waiting.status == "waiting"
      rows = Workflows.list_step_runs(waiting.id)
      assert Enum.count(rows, &(&1.status == "waiting")) == 1
      refute Enum.any?(rows, &String.starts_with?(&1.step_name, "m/tail"))
      refute Enum.any?(rows, &(&1.step_name == "m"))

      finished =
        Enum.reduce(1..3, waiting, fn _, run ->
          reloaded = Workflows.get_run!(run.id)
          assert reloaded.prepared_dag == nil
          approval = Workflows.get_pending_approval(run.id)
          assert approval != nil
          assert {:ok, next} = Workflows.approve_step(reloaded, approval, %{accepted: true}, nil)
          next
        end)

      assert finished.status == "completed"
      rows = Workflows.list_step_runs(finished.id)
      assert Enum.count(rows, &(&1.step_name == "emit")) == 1

      for index <- 0..2 do
        assert [review] = Enum.filter(rows, &(&1.step_name == "m/review[#{index}]"))
        assert review.status == "completed"
        assert [tail] = Enum.filter(rows, &(&1.step_name == "m/tail[#{index}]"))
        assert tail.status == "completed"
        assert tail.results["__map_index__"] == index
      end

      aggregate = Enum.find(rows, &(&1.step_name == "m"))
      assert aggregate.results["count"] == 3
      assert aggregate.results["errors"] == []
    end
  end
end
