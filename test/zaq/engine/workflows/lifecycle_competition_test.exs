defmodule Zaq.Engine.Workflows.LifecycleCompetitionTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Lifecycle competition #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "step",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.OkAction",
            params: %{},
            index: 0
          }
        ],
        edges: []
      })

    {:ok, run} =
      Workflows.create_run(workflow, %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual"},
        "trace_id" => Ecto.UUID.generate()
      })

    %{run: run}
  end

  for final_status <- ~w(completed failed incomplete waiting),
      operation <- [:pause, :cancel, :interrupt] do
    test "#{final_status} finalization then #{operation} preserves the first committed transition",
         %{run: run} do
      {:ok, running} = Workflows.transition_run_to_running(run)
      final_status = unquote(final_status)

      assert {:ok, {:transitioned, _}} = Workflows.finalize_run(running, %{status: final_status})
      assert_after_finalization(running, unquote(operation), final_status)

      expected =
        if unquote(operation) == :cancel and final_status == "waiting",
          do: "cancelled",
          else: final_status

      assert Workflows.get_run!(run.id).status == expected
    end

    test "#{operation} then #{final_status} finalization preserves the first committed transition",
         %{run: run} do
      {:ok, running} = Workflows.transition_run_to_running(run)
      final_status = unquote(final_status)

      expected = apply_operation(running, unquote(operation))

      assert {:ok, {:unchanged, %{status: ^expected}}} =
               Workflows.finalize_run(running, %{status: final_status})

      assert Workflows.get_run!(run.id).status == expected
    end
  end

  for operation <- [:cancel, :interrupt] do
    test "#{operation} then stale start cannot reopen a pending run", %{run: run} do
      apply_operation(run, unquote(operation))

      status = Workflows.get_run!(run.id).status
      assert {:error, {:invalid_run_status, ^status}} = Workflows.start_run(run)
      assert Workflows.get_run!(run.id).status == status
    end
  end

  for {first, second} <- [
        {:pause, :interrupt},
        {:interrupt, :pause},
        {:cancel, :interrupt},
        {:interrupt, :cancel},
        {:cancel, :pause}
      ] do
    test "#{first} before #{second} preserves the committed status", %{run: run} do
      {:ok, running} = Workflows.transition_run_to_running(run)
      expected = apply_operation(running, unquote(first))
      assert_losing_operation(running, unquote(second), expected)
      assert Workflows.get_run!(run.id).status == expected
    end
  end

  test "cancellation may follow a committed pause", %{run: run} do
    {:ok, running} = Workflows.transition_run_to_running(run)
    {:ok, paused} = Workflows.pause_run(running)
    assert {:ok, %{status: "cancelled"}} = Workflows.cancel_run(paused)
    assert Workflows.get_run!(run.id).status == "cancelled"
  end

  test "interruption against a paused row does not prevent a later resume", %{run: run} do
    {:ok, running} = Workflows.transition_run_to_running(run)
    {:ok, paused} = Workflows.pause_run(running)
    assert {:ok, %{status: "paused"}} = Workflows.interrupt_run(paused)
    assert {:ok, %{status: "completed"}} = Workflows.resume_run(paused)
  end

  test "interruption after a completed resume cannot reopen the run", %{run: run} do
    {:ok, running} = Workflows.transition_run_to_running(run)
    {:ok, paused} = Workflows.pause_run(running)
    assert {:ok, %{status: "completed"}} = Workflows.resume_run(paused)
    assert {:ok, %{status: "completed"}} = Workflows.interrupt_run(paused)
    assert Workflows.get_run!(run.id).status == "completed"
  end

  test "a later sibling progress tick preserves a staged Runic failure", %{run: run} do
    {:ok, running} = Workflows.transition_run_to_running(run)

    assert {:ok, {:transitioned, %{status: "failed"}}} =
             Workflows.finalize_run(running, %{
               status: "failed",
               log_summary: %{execution_error: "native map failure"}
             })

    {:ok, sibling} =
      Workflows.create_step_run(running, %{step_name: "sibling", step_index: 1})

    {:ok, _} = Workflows.complete_step_run(sibling, %{ok: true})
    :ok = Workflows.tick_log_summary(run.id)

    assert Workflows.get_run!(run.id).status == "failed"
    assert Workflows.get_run!(run.id).log_summary["execution_error"] == "native map failure"
  end

  for first <- [:build_failure, :interrupt] do
    test "#{first} wins the preparation failure versus interruption order" do
      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "Invalid preparation #{System.unique_integer()}",
          status: "draft",
          nodes: [],
          edges: []
        })

      {:ok, run} =
        Workflows.create_run(workflow, %{
          "request" => nil,
          "assigns" => %{"trigger_type" => "manual"},
          "trace_id" => Ecto.UUID.generate()
        })

      assert_build_failure_order(run, unquote(first))
    end
  end

  defp assert_after_finalization(run, :pause, _status),
    do: assert({:error, :not_running} = Workflows.pause_run(run))

  defp assert_after_finalization(run, :cancel, "waiting"),
    do: assert({:ok, %{status: "cancelled"}} = Workflows.cancel_run(run))

  defp assert_after_finalization(run, :cancel, _status),
    do: assert({:error, :already_finished} = Workflows.cancel_run(run))

  defp assert_after_finalization(run, :interrupt, status),
    do: assert({:ok, %{status: ^status}} = Workflows.interrupt_run(run))

  defp apply_operation(run, :pause) do
    assert {:ok, %{status: "paused"}} = Workflows.pause_run(run)
    "paused"
  end

  defp apply_operation(run, :cancel) do
    assert {:ok, %{status: "cancelled"}} = Workflows.cancel_run(run)
    "cancelled"
  end

  defp apply_operation(run, :interrupt) do
    assert {:ok, %{status: "interrupted"}} = Workflows.interrupt_run(run)
    "interrupted"
  end

  defp assert_losing_operation(run, :pause, _status),
    do: assert({:error, :not_running} = Workflows.pause_run(run))

  defp assert_losing_operation(run, :cancel, _status),
    do: assert({:error, :already_finished} = Workflows.cancel_run(run))

  defp assert_losing_operation(run, :interrupt, status),
    do: assert({:ok, %{status: ^status}} = Workflows.interrupt_run(run))

  defp assert_build_failure_order(run, :build_failure) do
    assert {:error, :empty_dag} = Workflows.start_run(run)
    assert {:ok, %{status: "failed"}} = Workflows.interrupt_run(run)
    assert Workflows.get_run!(run.id).status == "failed"
  end

  defp assert_build_failure_order(run, :interrupt) do
    assert {:ok, %{status: "interrupted"}} = Workflows.interrupt_run(run)
    assert {:error, {:invalid_run_status, "interrupted"}} = Workflows.start_run(run)
    assert Workflows.get_run!(run.id).status == "interrupted"
  end
end
