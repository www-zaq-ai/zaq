defmodule Zaq.Engine.Workflows do
  @moduledoc """
  Public API for workflow management and run lifecycle.

  Permission checks are the caller's responsibility before invoking these
  functions. Use `Zaq.Permissions.can?/4` to gate access.

  All Repo calls are encapsulated here — no direct Repo calls from outside
  this context.
  """

  import Ecto.Query

  alias Zaq.Engine.EventRegistry

  alias Zaq.Engine.Workflows.{
    Trigger,
    Workflow,
    WorkflowAgent,
    WorkflowRun
  }

  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Repo

  @type run_trace :: %{
          run_id: binary(),
          workflow_id: binary(),
          workflow_name: String.t() | nil,
          status: String.t(),
          trigger_type: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          steps: [
            %{
              step_name: String.t(),
              step_index: non_neg_integer(),
              status: String.t(),
              started_at: DateTime.t() | nil,
              finished_at: DateTime.t() | nil,
              duration_ms: non_neg_integer() | nil,
              results: map() | nil,
              errors: map() | nil,
              logs: [map()]
            }
          ],
          log_summary: map() | nil
        }

  # --- Run execution ---

  @doc """
  Executes a `WorkflowRun` by delegating to `WorkflowAgent`.

  Builds the instrumented DAG from `run.steps_snapshot`, drives each step
  synchronously, writes `StepRun` rows per step, and updates
  `WorkflowRun.status` to `"completed"` or `"failed"`.

  Returns `{:ok, updated_run}` on success or `{:error, reason}` on failure.
  """
  @spec start_run(WorkflowRun.t(), keyword()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def start_run(%WorkflowRun{} = run, opts \\ []) do
    WorkflowAgent.execute(run, opts)
  end

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
      steps_snapshot: serialize_steps(workflow),
      settings_snapshot: workflow.settings,
      source_event: source_event,
      status: "pending"
    })
    |> Repo.insert()
  end

  defp serialize_steps(%Workflow{nodes: nodes, edges: edges}) do
    %{
      "nodes" =>
        Enum.map(nodes || [], fn n ->
          %{
            "name" => n.name,
            "type" => n.type,
            "module" => n.module,
            "index" => n.index,
            "params" => n.params || %{}
          }
        end),
      "edges" =>
        Enum.map(edges || [], fn e ->
          %{"from" => e.from, "to" => e.to}
        end)
    }
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

  # --- Step runs ---

  @doc """
  Creates a step run row with `status: running` before a step executes.
  This is the crash-safe cursor — on node restart, the agent queries these rows
  to resume from the correct step.
  """
  @spec create_step_run(WorkflowRun.t(), map(), keyword()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}
  def create_step_run(%WorkflowRun{} = run, attrs, _opts \\ []) do
    attrs =
      attrs
      |> Map.put(:workflow_run_id, run.id)
      |> Map.put_new(:started_at, DateTime.utc_now(:second))

    %StepRun{}
    |> StepRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Marks a step run as completed, recording the result map and finished_at.

  Accepts an optional `logs` list — structured log entries emitted by the action.
  Each entry should be a map with at least `%{level: "info"|"warn"|"error", message: string}`.
  """
  @spec complete_step_run(StepRun.t(), map(), [map()], keyword()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}
  def complete_step_run(%StepRun{} = step_run, results, logs \\ [], _opts \\ []) do
    step_run
    |> StepRun.changeset(%{
      status: "completed",
      results: results,
      logs: logs,
      finished_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  @doc "Marks a step run as failed, recording the error map and finished_at."
  @spec fail_step_run(StepRun.t(), map(), keyword()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}
  def fail_step_run(%StepRun{} = step_run, errors, _opts \\ []) do
    step_run
    |> StepRun.changeset(%{
      status: "failed",
      errors: errors,
      finished_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  @doc "Marks a step run as skipped when a condition evaluated to false."
  @spec skip_step_run(StepRun.t(), map(), keyword()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}
  def skip_step_run(%StepRun{} = step_run, metadata \\ %{}, _opts \\ []) do
    step_run
    |> StepRun.changeset(%{
      status: "skipped",
      results: metadata,
      finished_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  @doc """
  Returns all step runs for a workflow run, ordered by step_index ascending.

  Used by `WorkflowAgent` on boot to rehydrate:
  - All `completed` rows → rebuild `previous_results` map
  - Last `running` row → the step to resume (was mid-flight on crash)
  """
  @spec list_step_runs(term(), keyword()) :: [StepRun.t()]
  def list_step_runs(run_id, _opts \\ []) do
    Repo.all(
      from sr in StepRun,
        where: sr.workflow_run_id == ^run_id,
        order_by: [asc: sr.step_index]
    )
  end

  # --- Trace ---

  @doc """
  Returns a structured execution trace for a workflow run.

  Loads the `WorkflowRun` (with its parent `Workflow`) and all `StepRun` rows,
  and assembles them into a single map ordered by step index. Durations are
  computed from stored timestamps (second precision).

  Intended for client-facing diagnostics: pass the returned map to support when
  a workflow fails. Every field needed to identify the root cause is present.
  """
  @spec get_run_trace(binary()) :: run_trace()
  def get_run_trace(run_id) do
    run = Repo.get!(WorkflowRun, run_id) |> Repo.preload(:workflow)
    step_runs = list_step_runs(run_id)

    %{
      run_id: run.id,
      workflow_id: run.workflow_id,
      workflow_name: run.workflow && run.workflow.name,
      status: run.status,
      trigger_type: run.source_event && to_string(run.source_event.assigns[:trigger_type] || ""),
      started_at: run.started_at,
      finished_at: run.finished_at,
      duration_ms: duration_ms(run.started_at, run.finished_at),
      steps: Enum.map(step_runs, &step_run_to_trace/1),
      log_summary: run.log_summary
    }
  end

  defp step_run_to_trace(%StepRun{} = sr) do
    %{
      step_name: sr.step_name,
      step_index: sr.step_index,
      status: sr.status,
      started_at: sr.started_at,
      finished_at: sr.finished_at,
      duration_ms: duration_ms(sr.started_at, sr.finished_at),
      results: sr.results,
      errors: sr.errors,
      logs: sr.logs || []
    }
  end

  defp duration_ms(nil, _), do: nil
  defp duration_ms(_, nil), do: nil

  defp duration_ms(%DateTime{} = start, %DateTime{} = finish),
    do: DateTime.diff(finish, start, :millisecond)

  # --- Triggers ---

  @doc "Lists all triggers."
  @spec list_triggers(keyword()) :: [Trigger.t()]
  def list_triggers(_opts \\ []) do
    Repo.all(from t in Trigger, order_by: [asc: t.inserted_at])
  end

  @doc "Returns triggers assigned to a workflow, ordered by position."
  @spec list_triggers_for_workflow(term(), keyword()) :: [Trigger.t()]
  def list_triggers_for_workflow(workflow_id, _opts \\ []) do
    Repo.all(
      from t in Trigger,
        join: tw in "trigger_workflows",
        on: tw.trigger_id == t.id,
        where: type(tw.workflow_id, :binary_id) == ^workflow_id,
        order_by: [asc: tw.position]
    )
  end

  @doc """
  Returns active workflows linked to a trigger by its `event_name` string.

  Only workflows with `status: "active"` are returned. Used by `TriggerNode`
  to determine which workflows to fire when a trigger event is received.
  """
  @spec list_workflows_for_trigger(String.t(), keyword()) :: [Workflow.t()]
  def list_workflows_for_trigger(event_name, _opts \\ []) when is_binary(event_name) do
    Repo.all(
      from w in Workflow,
        join: tw in "trigger_workflows",
        on: type(tw.workflow_id, :binary_id) == w.id,
        join: t in Trigger,
        on: t.id == type(tw.trigger_id, :binary_id),
        where: t.event_name == ^event_name and t.enabled == true and w.status == "active",
        order_by: [asc: tw.position]
    )
  end

  @doc """
  Returns all enabled trigger event_name strings.

  Used by `Engine.EventRegistry` on startup to pre-load which event names
  are registered triggers.
  """
  @spec list_trigger_event_names(keyword()) :: [String.t()]
  def list_trigger_event_names(_opts \\ []) do
    Repo.all(
      from t in Trigger,
        where: t.enabled == true,
        select: t.event_name
    )
  end

  @doc "Gets a trigger by id, raising if not found."
  @spec get_trigger!(term()) :: Trigger.t()
  def get_trigger!(id) do
    Repo.get!(Trigger, id)
    |> Repo.preload([:workflows])
  end

  @doc "Creates a standalone trigger with no workflows assigned."
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
    with {:ok, updated} <- trigger |> Trigger.changeset(attrs) |> Repo.update() do
      sync_registry(updated)
      {:ok, updated}
    end
  end

  defp sync_registry(%Trigger{event_name: name, enabled: true}) do
    if Process.whereis(EventRegistry), do: EventRegistry.activate(name)
    :ok
  end

  defp sync_registry(%Trigger{event_name: name, enabled: false}) do
    if Process.whereis(EventRegistry), do: EventRegistry.deactivate(name)
    :ok
  end

  @doc "Deletes a trigger. Cascades to trigger_workflows via FK."
  @spec delete_trigger(Trigger.t(), keyword()) :: {:ok, Trigger.t()} | {:error, term()}
  def delete_trigger(%Trigger{} = trigger, _opts \\ []) do
    Repo.delete(trigger)
  end

  @doc """
  Assigns a workflow to a trigger. Idempotent — a second call with the same pair
  succeeds without inserting a duplicate row.

  `opts` accepts `position: integer` (default 0) for ordering.
  """
  @spec assign_workflow_to_trigger(Trigger.t(), Workflow.t(), keyword()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def assign_workflow_to_trigger(%Trigger{} = trigger, %Workflow{} = workflow, opts \\ []) do
    position = Keyword.get(opts, :position, 0)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, id} = Ecto.UUID.dump(Ecto.UUID.generate())
    {:ok, trigger_id} = Ecto.UUID.dump(trigger.id)
    {:ok, workflow_id} = Ecto.UUID.dump(workflow.id)

    Repo.insert_all(
      "trigger_workflows",
      [
        %{
          id: id,
          trigger_id: trigger_id,
          workflow_id: workflow_id,
          position: position,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:position, :updated_at]},
      conflict_target: [:trigger_id, :workflow_id],
      returning: [:trigger_id, :workflow_id, :position]
    )
    |> case do
      {_, [row | _]} -> {:ok, row}
      {_, []} -> {:ok, %{trigger_id: trigger.id, workflow_id: workflow.id, position: position}}
    end
  end

  @doc "Removes a workflow assignment from a trigger."
  @spec remove_workflow_from_trigger(Trigger.t(), Workflow.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def remove_workflow_from_trigger(%Trigger{} = trigger, %Workflow{} = workflow, _opts \\ []) do
    query =
      from tw in "trigger_workflows",
        where:
          type(tw.trigger_id, :binary_id) == ^trigger.id and
            type(tw.workflow_id, :binary_id) == ^workflow.id

    case Repo.delete_all(query) do
      {1, _} -> {:ok, %{trigger_id: trigger.id, workflow_id: workflow.id}}
      {0, _} -> {:error, :not_found}
    end
  end
end
