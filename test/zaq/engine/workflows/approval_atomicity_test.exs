defmodule Zaq.Engine.Workflows.ApprovalAtomicityTest do
  use Zaq.DataCase, async: false

  import ExUnit.CaptureLog

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.{StepApproval, WorkflowRun}
  alias Zaq.Repo

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "approval-atomicity-#{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "review",
            type: "action",
            module: "Zaq.Engine.Workflows.Steps.HumanInTheLoop",
            params: %{"message" => "Review"},
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

    {:ok, run} = Workflows.update_run(run, %{status: "waiting"})
    {:ok, step} = Workflows.create_step_run(run, %{step_name: "review", step_index: 0})
    {:ok, _step} = Workflows.wait_step_run(step)

    {:ok, approval} =
      Workflows.create_approval(%{
        workflow_run_id: run.id,
        step_name: "review",
        approval_token: Ecto.UUID.generate(),
        status: "pending"
      })

    %{run: run, approval: approval}
  end

  for {decision, target_status} <- [{:approve, "paused"}, {:reject, "failed"}] do
    test "#{decision} emits no lifecycle update when its run write rolls back", context do
      %{run: run, approval: approval} = context

      # The constraint makes the last write in the approval transaction fail.
      # It is scoped to this sandbox transaction and removed on rollback.
      constraint = "approval_atomicity_#{System.unique_integer([:positive])}"

      Repo.query!(
        "ALTER TABLE workflow_runs ADD CONSTRAINT #{constraint} " <>
          "CHECK (status <> '#{unquote(target_status)}')"
      )

      test_pid = self()

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(test_pid, {:observed, event})
        event
      end)

      try do
        case unquote(decision) do
          :approve -> Workflows.approve_step(run, approval, %{}, nil)
          :reject -> Workflows.reject_step(run, approval, "denied", nil)
        end
      rescue
        _ -> :ok
      end

      refute_received {:observed, _}
      assert %WorkflowRun{status: "waiting"} = Workflows.get_run!(run.id)
      assert [%{status: "waiting"}] = Workflows.list_step_runs(run.id)
      assert %StepApproval{status: "pending"} = Workflows.get_step_approval(run.id, "review")
    end
  end

  for {decision, final_status, approval_status, step_status} <- [
        {:approve, "completed", "approved", "completed"},
        {:reject, "failed", "rejected", "failed"}
      ] do
    test "#{decision} keeps committed state when UI broadcasts raise", context do
      %{run: run, approval: approval} = context

      stub(Zaq.NodeRouterMock, :dispatch, fn
        %Zaq.Event{request: {:broadcast, _, _}} -> raise "observer failed"
        event -> event
      end)

      capture_log(fn ->
        case unquote(decision) do
          :approve -> assert {:ok, _} = Workflows.approve_step(run, approval, %{}, nil)
          :reject -> assert {:ok, _} = Workflows.reject_step(run, approval, "denied", nil)
        end
      end)

      assert %WorkflowRun{status: unquote(final_status)} = Workflows.get_run!(run.id)
      assert [%{status: unquote(step_status)}] = Workflows.list_step_runs(run.id)

      assert %StepApproval{status: unquote(approval_status)} =
               Workflows.get_step_approval(run.id, "review")
    end
  end

  for decision <- [:approve, :reject] do
    test "cancellation before #{decision} rejects the stale decision", %{
      run: run,
      approval: approval
    } do
      assert {:ok, %{status: "cancelled"}} = Workflows.cancel_run(run)

      assert {:error, :not_waiting} = decide(unquote(decision), run, approval)
      assert %WorkflowRun{status: "cancelled"} = Workflows.get_run!(run.id)
      assert %StepApproval{status: "pending"} = Workflows.get_step_approval(run.id, "review")
    end

    test "#{decision} before cancellation keeps the decided terminal state",
         %{run: run, approval: approval} do
      assert {:ok, decided} = decide(unquote(decision), run, approval)
      assert {:error, :already_finished} = Workflows.cancel_run(run)
      assert Workflows.get_run!(run.id).status == decided.status
    end
  end

  for {first, second} <- [
        {:approve, :approve},
        {:approve, :reject},
        {:reject, :approve},
        {:reject, :reject}
      ] do
    test "#{first} before #{second} does not admit a second decision",
         %{run: run, approval: approval} do
      assert {:ok, first_run} = decide(unquote(first), run, approval)
      assert {:error, :not_waiting} = decide(unquote(second), run, approval)
      assert Workflows.get_run!(run.id).status == first_run.status

      assert Workflows.get_step_approval(run.id, "review").status ==
               if(unquote(first) == :approve, do: "approved", else: "rejected")
    end
  end

  defp decide(:approve, run, approval), do: Workflows.approve_step(run, approval, %{}, nil)
  defp decide(:reject, run, approval), do: Workflows.reject_step(run, approval, "denied", nil)
end
