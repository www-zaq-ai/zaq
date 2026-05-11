defmodule Zaq.Workflows do
  @moduledoc """
  Public API for workflow management and run lifecycle.

  Permission checks are the caller's responsibility before invoking these
  functions. Use `Zaq.Permissions.can?/4` to gate access.

  All Repo calls are encapsulated here — no direct Repo calls from outside
  this context.
  """

  import Ecto.Query

  alias Zaq.Repo
  alias Zaq.Workflows.{ActionResult, Trigger, Workflow, WorkflowRun}

  # --- Workflows ---

  @doc "Returns all workflows ordered by name."
  @spec list_workflows(keyword()) :: [Workflow.t()]
  def list_workflows(_opts \\ []) do
    Repo.all(from w in Workflow, order_by: [asc: w.name])
  end

  @doc "Gets a workflow by id, raising if not found."
  @spec get_workflow!(term()) :: Workflow.t()
  def get_workflow!(id), do: Repo.get!(Workflow, id)

  @doc "Creates a workflow."
  @spec create_workflow(map(), keyword()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_workflow(attrs, _opts \\ []) do
    %Workflow{}
    |> Workflow.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a workflow."
  @spec update_workflow(Workflow.t(), map(), keyword()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def update_workflow(%Workflow{} = workflow, attrs, _opts \\ []) do
    workflow
    |> Workflow.changeset(attrs)
    |> Repo.update()
  end

  @doc "Archives a workflow (soft-delete). Does not delete run history."
  @spec archive_workflow(Workflow.t(), keyword()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def archive_workflow(%Workflow{} = workflow, _opts \\ []) do
    workflow
    |> Workflow.changeset(%{status: "archived"})
    |> Repo.update()
  end

  # --- Runs ---

  @doc """
  Creates a workflow run, snapshotting steps and settings at creation time.

  The `WorkflowAgent` reads exclusively from these snapshots — editing the
  workflow after a run starts never affects the in-progress run.

  `source_event` must be a map representation of `%Zaq.Event{}`.
  """
  @spec create_run(Workflow.t(), map(), map(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def create_run(%Workflow{} = workflow, source_event, _context \\ %{}, _opts \\ []) do
    %WorkflowRun{}
    |> WorkflowRun.changeset(%{
      workflow_id: workflow.id,
      steps_snapshot: workflow.steps,
      settings_snapshot: workflow.settings,
      source_event: source_event,
      status: "pending"
    })
    |> Repo.insert()
  end

  @doc "Gets a workflow run by id, raising if not found."
  @spec get_run!(term()) :: WorkflowRun.t()
  def get_run!(id), do: Repo.get!(WorkflowRun, id)

  @doc "Updates a workflow run."
  @spec update_run(WorkflowRun.t(), map(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def update_run(%WorkflowRun{} = run, attrs, _opts \\ []) do
    run
    |> WorkflowRun.changeset(attrs)
    |> Repo.update()
  end

  @doc "Lists all runs for a workflow, ordered by insertion time descending."
  @spec list_runs(term(), keyword()) :: [WorkflowRun.t()]
  def list_runs(workflow_id, _opts \\ []) do
    Repo.all(
      from r in WorkflowRun,
        where: r.workflow_id == ^workflow_id,
        order_by: [desc: r.inserted_at, desc: r.id]
    )
  end

  # --- Action results ---

  @doc """
  Creates an action result row with `status: running` before a step executes.
  This is the crash-safe cursor — on node restart, the agent queries these rows
  to resume from the correct step.
  """
  @spec create_action_result(WorkflowRun.t(), map(), keyword()) ::
          {:ok, ActionResult.t()} | {:error, Ecto.Changeset.t()}
  def create_action_result(%WorkflowRun{} = run, attrs, _opts \\ []) do
    attrs =
      attrs
      |> Map.put(:workflow_run_id, run.id)
      |> Map.put_new(:started_at, DateTime.utc_now(:second))

    %ActionResult{}
    |> ActionResult.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Marks an action result as completed, recording the result map and finished_at."
  @spec complete_action_result(ActionResult.t(), map(), keyword()) ::
          {:ok, ActionResult.t()} | {:error, Ecto.Changeset.t()}
  def complete_action_result(%ActionResult{} = action_result, results, _opts \\ []) do
    action_result
    |> ActionResult.changeset(%{
      status: "completed",
      results: results,
      finished_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  @doc "Marks an action result as failed, recording the error map and finished_at."
  @spec fail_action_result(ActionResult.t(), map(), keyword()) ::
          {:ok, ActionResult.t()} | {:error, Ecto.Changeset.t()}
  def fail_action_result(%ActionResult{} = action_result, errors, _opts \\ []) do
    action_result
    |> ActionResult.changeset(%{
      status: "failed",
      errors: errors,
      finished_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  @doc """
  Returns all action results for a run, ordered by step_index ascending.

  Used by `WorkflowAgent` on boot to rehydrate:
  - All `completed` rows → rebuild `previous_results` map
  - Last `running` row → the step to resume (was mid-flight on crash)
  """
  @spec list_action_results(term(), keyword()) :: [ActionResult.t()]
  def list_action_results(run_id, _opts \\ []) do
    Repo.all(
      from ar in ActionResult,
        where: ar.workflow_run_id == ^run_id,
        order_by: [asc: ar.step_index]
    )
  end

  # --- Triggers ---

  @doc "Lists all triggers for a workflow."
  @spec list_triggers(term(), keyword()) :: [Trigger.t()]
  def list_triggers(workflow_id, _opts \\ []) do
    Repo.all(from t in Trigger, where: t.workflow_id == ^workflow_id)
  end

  @doc "Creates a trigger for a workflow."
  @spec create_trigger(map(), keyword()) :: {:ok, Trigger.t()} | {:error, Ecto.Changeset.t()}
  def create_trigger(attrs, _opts \\ []) do
    %Trigger{}
    |> Trigger.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a trigger."
  @spec update_trigger(Trigger.t(), map(), keyword()) ::
          {:ok, Trigger.t()} | {:error, Ecto.Changeset.t()}
  def update_trigger(%Trigger{} = trigger, attrs, _opts \\ []) do
    trigger
    |> Trigger.changeset(attrs)
    |> Repo.update()
  end
end
