defmodule Zaq.Engine.Workflows do
  @moduledoc """
  Public API for workflow management and run lifecycle.

  Permission checks are the caller's responsibility before invoking these
  functions. Use `Zaq.Permissions.can?/4` to gate access.

  All Repo calls are encapsulated here — no direct Repo calls from outside
  this context.
  """

  import Ecto.Query

  require Logger

  alias Zaq.Engine.EventRegistry

  alias Zaq.Engine.Workflows.{
    Composition,
    CronTriggerWorker,
    DagBuilder,
    StepApproval,
    Trigger,
    Workflow,
    WorkflowRun,
    WorkflowRunAgent
  }

  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Oban.DynamicCron
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
  Starts a pending `WorkflowRun` by delegating execution to `WorkflowRunAgent`.

  Guarantees the run carries an executable DAG (`ensure_prepared_dag/1`) before
  handing it to the agent, which then only *runs* it. Drives each step
  synchronously, writes `StepRun` rows per step, and updates
  `WorkflowRun.status` to `"completed"` or `"failed"`.

  Emits the `{:run_started, run}` UI broadcast on `"workflow:<workflow_id>"`
  (via the Channels role) — the counterpart to `create_run/4`'s `:run_created`.
  Bare `create_run/4` never signals a start; only `start_run/2` does. A run whose
  DAG cannot be prepared is failed (no `:run_started` is emitted) and the build
  error is returned.

  Returns `{:ok, updated_run}` on success, `{:error, reason}` on a build or
  execution failure, or `{:error, {:invalid_run_status, status}}` when the run is
  not pending.
  """
  @spec start_run(WorkflowRun.t(), keyword()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def start_run(%WorkflowRun{status: "pending"} = run, opts) do
    with {:ok, run} <- ensure_prepared_dag(run) do
      dispatch_async("workflow:#{run.workflow_id}", {:run_started, run})
      WorkflowRunAgent.execute(run, opts)
    end
  end

  def start_run(%WorkflowRun{status: status}, _opts) do
    {:error, {:invalid_run_status, status}}
  end

  def start_run(%WorkflowRun{} = run), do: start_run(run, [])

  @doc """
  Creates a pending workflow run and immediately starts it.

  Use this for synchronous trigger paths that do not need to inspect or persist
  the pending run before execution. Use `create_run/4` and `start_run/2`
  separately when callers need a durable pending run boundary.
  """
  @spec create_and_start_run(Workflow.t(), map(), map(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, term()}
  def create_and_start_run(%Workflow{} = workflow, source_event, context \\ %{}, opts \\ []) do
    with {:ok, run} <- create_run(workflow, source_event, context, opts) do
      start_run(run, opts)
    end
  end

  @doc """
  Guarantees the run carries an executable `prepared_dag`, so the agent only has
  to *run* it (it never builds a DAG).

  Reuses an already-prepared DAG when present (e.g. the in-memory DAG
  `create_run/4` attaches); otherwise builds it from `steps_snapshot`. A reload
  from the DB drops the virtual `prepared_dag`, so the resume/start paths rebuild
  here. On a build failure — only reachable via **code drift**, since save-time
  validation rejects unrunnable workflows — the run is marked `failed`, a
  `run.failed` lifecycle event is dispatched, and `{:error, reason}` is returned.
  """
  @spec ensure_prepared_dag(WorkflowRun.t()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def ensure_prepared_dag(%WorkflowRun{prepared_dag: dag} = run) when not is_nil(dag),
    do: {:ok, run}

  def ensure_prepared_dag(%WorkflowRun{} = run) do
    case DagBuilder.build(run.steps_snapshot, run_id: run.id) do
      {:ok, dag} ->
        {:ok, %{run | prepared_dag: dag}}

      {:error, reason} ->
        Logger.error("[workflow] run failed to start",
          workflow_id: run.workflow_id,
          run_id: run.id,
          error: inspect(reason)
        )

        update_run(run, %{
          status: "failed",
          finished_at: DateTime.utc_now(:second),
          log_summary: %{
            error: format_build_error(reason),
            failed_step_count: 0,
            failed_steps: [],
            step_count: 0
          }
        })

        dispatch_workflow_event("run.failed", %{run_id: run.id, workflow_id: run.workflow_id})
        {:error, reason}
    end
  end

  @doc """
  Cancels a workflow run that is still in progress.

  Accepts runs in `"pending"`, `"running"`, or `"waiting"` status. Marks the
  run as `"cancelled"` and marks any in-progress step runs accordingly.
  Returns `{:error, :already_finished}` if the run has already reached a
  terminal state.
  """
  @spec cancel_run(WorkflowRun.t(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, :already_finished | Ecto.Changeset.t()}
  def cancel_run(%WorkflowRun{} = run, _opts \\ []) do
    if run.status in ["pending", "running", "waiting", "paused"] do
      # Hard-kill any executing WorkflowRunAgent process for this run
      Registry.lookup(Zaq.Engine.Workflows.RunRegistry, run.id)
      |> Enum.each(fn {pid, _} -> Process.exit(pid, :kill) end)

      Repo.transaction(fn ->
        {:ok, cancelled_run} =
          update_run(run, %{status: "cancelled", finished_at: DateTime.utc_now(:second)})

        from(sr in StepRun,
          where:
            sr.workflow_run_id == ^run.id and
              sr.status in ["pending", "running", "waiting", "paused"]
        )
        |> Repo.update_all(set: [status: "cancelled", updated_at: DateTime.utc_now(:second)])

        cancelled_run
      end)
      |> case do
        {:ok, cancelled_run} -> {:ok, cancelled_run}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :already_finished}
    end
  end

  @doc """
  Pauses a running workflow run immediately.

  Hard-kills the executing `WorkflowRunAgent` process so the current step stops
  at once, then in a single transaction marks the run `"paused"` and any
  in-flight `StepRun` rows `"paused"`.

  On resume, `StepRunner` sees the `"paused"` step_run as non-terminal
  (not in `completed/failed/skipped/waiting`) and re-executes it from the
  beginning.

  Returns `{:error, :not_running}` if the run is not in `"running"` state.
  """
  @spec pause_run(WorkflowRun.t(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, :not_running | Ecto.Changeset.t()}
  def pause_run(%WorkflowRun{} = run, _opts \\ []) do
    case run.status do
      "running" ->
        # Kill the agent so the current step stops immediately
        Registry.lookup(Zaq.Engine.Workflows.RunRegistry, run.id)
        |> Enum.each(fn {pid, _} -> Process.exit(pid, :kill) end)

        result =
          Repo.transaction(fn ->
            {:ok, paused_run} = update_run(run, %{status: "paused"})

            now = DateTime.utc_now(:second)

            from(sr in StepRun,
              where: sr.workflow_run_id == ^run.id and sr.status == "running"
            )
            |> Repo.update_all(set: [status: "paused", finished_at: now, updated_at: now])

            paused_run
          end)

        case result do
          {:ok, paused_run} ->
            # Broadcast each paused step_run so all subscribers update in real-time
            Repo.all(
              from sr in StepRun,
                where: sr.workflow_run_id == ^run.id and sr.status == "paused"
            )
            |> Enum.each(&broadcast_step({:ok, &1}))

            {:ok, paused_run}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :not_running}
    end
  end

  @doc """
  Resumes a paused workflow run from where it stopped.

  Delegates to `WorkflowRunAgent.execute/2`. `StepRunner` skips any step whose
  `StepRun` is already `"completed"`, so the run continues from the first
  incomplete step. Returns `{:error, :not_paused}` if the run is not paused.
  """
  @spec resume_run(WorkflowRun.t(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, :not_paused | term()}
  def resume_run(%WorkflowRun{} = run, opts \\ []) do
    case run.status do
      "paused" ->
        with {:ok, run} <- ensure_prepared_dag(run) do
          WorkflowRunAgent.execute(run, opts)
        end

      _ ->
        {:error, :not_paused}
    end
  end

  @doc """
  Retries an interrupted, failed, or cancelled workflow run by creating a new
  run for the same workflow, reusing the original `source_event`.

  Returns `{:error, :not_retryable}` if the run is not in a retryable state.
  """
  @spec retry_run(WorkflowRun.t(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, :not_retryable | Ecto.Changeset.t()}
  def retry_run(%WorkflowRun{} = run, _opts \\ []) do
    if run.status in ["interrupted", "failed", "cancelled"] do
      workflow = get_workflow!(run.workflow_id)
      create_run(workflow, run.source_event)
    else
      {:error, :not_retryable}
    end
  end

  # --- Workflows ---

  @doc "Returns all workflows ordered by name."
  @spec list_workflows(keyword()) :: [Workflow.t()]
  def list_workflows(_opts \\ []) do
    Repo.all(from w in Workflow, order_by: [asc: w.name])
  end

  @doc """
  Returns all workflows with their run counts and assigned triggers.

  Returns a list of `{workflow, run_count, triggers}` tuples ordered by
  workflow name ascending. Used by the BO list page.
  """
  @spec list_workflows_with_run_counts_and_triggers() :: [
          {Workflow.t(), non_neg_integer(), [Trigger.t()]}
        ]
  def list_workflows_with_run_counts_and_triggers do
    workflows = Repo.all(from w in Workflow, order_by: [asc: w.name])

    Enum.map(workflows, fn w ->
      {w, count_runs(w.id), list_triggers_for_workflow(w.id)}
    end)
  end

  @doc """
  Like `list_workflows_with_run_counts_and_triggers/0` but also includes the
  latest `WorkflowRun` for each workflow (or `nil` when there are no runs).

  Returns `{workflow, run_count, triggers, latest_run}` tuples.
  """
  @spec list_workflows_with_details() :: [
          {Workflow.t(), non_neg_integer(), [Trigger.t()], WorkflowRun.t() | nil}
        ]
  def list_workflows_with_details do
    workflows = Repo.all(from w in Workflow, order_by: [asc: w.name])

    latest_runs =
      from(r in WorkflowRun,
        distinct: r.workflow_id,
        order_by: [asc: r.workflow_id, desc: r.inserted_at],
        select: r
      )
      |> Repo.all()
      |> Map.new(&{&1.workflow_id, &1})

    Enum.map(workflows, fn w ->
      {w, count_runs(w.id), list_triggers_for_workflow(w.id), Map.get(latest_runs, w.id)}
    end)
  end

  @doc "Gets a workflow by id, raising if not found."
  @spec get_workflow!(term()) :: Workflow.t()
  def get_workflow!(id), do: Repo.get!(Workflow, id)

  @doc """
  Creates a workflow.

  Dispatches a `"workflow.created"` event via NodeRouter on success.
  """
  @spec create_workflow(map(), keyword()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def create_workflow(attrs, _opts \\ []) do
    case %Workflow{} |> Workflow.changeset(attrs) |> validate_composition() |> Repo.insert() do
      {:ok, workflow} = result ->
        node_router().dispatch(
          Zaq.Event.new(%{action: "workflow.created", workflow_id: workflow.id}, :engine,
            name: :workflow
          )
        )

        result

      error ->
        error
    end
  end

  @doc "Updates a workflow."
  @spec update_workflow(Workflow.t(), map(), keyword()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def update_workflow(%Workflow{} = workflow, attrs, _opts \\ []) do
    workflow
    |> Workflow.changeset(attrs)
    |> validate_composition()
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

  @doc """
  Permanently deletes a workflow and all associated run history.

  Deletes all `WorkflowRun` rows for the workflow (which cascades to step runs
  and approvals via DB FK), then deletes the workflow itself (which cascades to
  trigger_workflow join rows).
  """
  @spec delete_workflow(Workflow.t(), keyword()) :: {:ok, Workflow.t()} | {:error, term()}
  def delete_workflow(%Workflow{} = workflow, _opts \\ []) do
    Repo.transaction(fn ->
      from(r in WorkflowRun, where: r.workflow_id == ^workflow.id)
      |> Repo.delete_all()

      case Repo.delete(workflow) do
        {:ok, deleted} -> deleted
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Exports a workflow as a plain map suitable for JSON serialisation.

  The output can be passed back to `import_workflow/1` to recreate the workflow.
  """
  @spec export_workflow(Workflow.t()) :: map()
  def export_workflow(%Workflow{} = workflow) do
    steps = serialize_steps(workflow)

    %{
      "name" => workflow.name,
      "description" => workflow.description,
      "status" => workflow.status,
      "settings" => workflow.settings || %{},
      "nodes" => steps["nodes"],
      "edges" => steps["edges"]
    }
  end

  @doc """
  Creates a workflow from an exported map.

  Always sets `status` to `"active"` regardless of the exported value so the
  workflow is immediately usable after import.
  Returns `{:error, changeset}` if the map is missing required fields.
  """
  @spec import_workflow(map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def import_workflow(attrs) when is_map(attrs) do
    attrs
    |> Map.put("status", "active")
    |> create_workflow()
  end

  # --- Runs ---

  @doc """
  Creates a pending workflow run, snapshotting steps and settings at creation time.

  The `WorkflowRunAgent` reads exclusively from these snapshots — editing the
  workflow after a run starts never affects the in-progress run.

  This function does not execute the run. Call `start_run/2` to transition the
  pending run into execution.

  On success the returned run carries its assembled DAG on the `prepared_dag`
  virtual field (built from the snapshot with the run id so action nodes are
  instrumented). The DAG holds closures and is never persisted — it lives only
  on the in-memory struct. Preparation is best-effort: if the snapshot cannot be
  built (e.g. an invalid workflow) `prepared_dag` stays `nil` and the run is
  still created pending, surfacing the build error when it is started.

  `source_event` must be a map representation of `%Zaq.Event{}`.
  """
  @spec create_run(Workflow.t(), map(), map(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def create_run(%Workflow{} = workflow, source_event, _context \\ %{}, _opts \\ []) do
    result =
      %WorkflowRun{}
      |> WorkflowRun.changeset(%{
        workflow_id: workflow.id,
        steps_snapshot: build_run_snapshot(workflow),
        settings_snapshot: workflow.settings,
        source_event: source_event,
        status: "pending"
      })
      |> Repo.insert()

    case result do
      {:ok, run} ->
        run = %{run | prepared_dag: prepare_dag(run)}
        dispatch_async("workflow:#{run.workflow_id}", {:run_created, run})
        {:ok, run}

      _ ->
        result
    end
  end

  # Snapshots the workflow's steps and splices any `"workflow"` reference nodes
  # inline (D1/D2: resolved fresh per run, frozen into this snapshot for the run's
  # lifetime). Best-effort: on a composition error the raw snapshot is kept so the
  # build error surfaces at start time rather than blocking run creation.
  defp build_run_snapshot(%Workflow{} = workflow) do
    raw = serialize_steps(workflow)

    case Composition.expand(raw, &resolve_workflow_ref/1) do
      {:ok, flat} -> flat
      {:error, _reason} -> raw
    end
  end

  defp resolve_workflow_ref(id) do
    case Repo.get(Workflow, id) do
      nil -> {:error, {:workflow_ref_not_found, id}}
      %Workflow{} = workflow -> {:ok, serialize_steps(workflow)}
    end
  end

  # Save-time composition validation (D5): rejects dangling references, single
  # root/leaf violations, reference cycles, and any composition whose flattened
  # graph is not acyclic. The resolver is self-aware — it returns the workflow's
  # own *pending* snapshot for its id, so a cycle introduced by the edit being
  # saved (e.g. B -> A -> B) is detected before it persists.
  defp validate_composition(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_composition(%Ecto.Changeset{} = changeset) do
    applied = Ecto.Changeset.apply_changes(changeset)
    snapshot = serialize_steps(applied)

    case Composition.validate(snapshot, composition_resolver(applied.id, snapshot)) do
      :ok ->
        changeset

      {:error, reason} ->
        Ecto.Changeset.add_error(changeset, :nodes, "invalid workflow composition",
          reason: reason
        )
    end
  end

  defp composition_resolver(self_id, self_snapshot) do
    fn
      ^self_id when not is_nil(self_id) -> {:ok, self_snapshot}
      id -> resolve_workflow_ref(id)
    end
  end

  # Assembles the run's DAG in-memory (closures — never persisted). Best-effort:
  # returns nil when the snapshot cannot be built so a pending run is still
  # created and the build error surfaces at start time.
  defp prepare_dag(%WorkflowRun{} = run) do
    case DagBuilder.build(run.steps_snapshot, run_id: run.id) do
      {:ok, dag} -> dag
      {:error, _reason} -> nil
    end
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
          edge = %{"from" => e.from, "to" => e.to}
          edge = if e.condition, do: Map.put(edge, "condition", e.condition), else: edge
          if map_size(e.mapping || %{}) > 0, do: Map.put(edge, "mapping", e.mapping), else: edge
        end)
    }
  end

  @doc "Gets a workflow run by id, returning nil if not found."
  @spec get_run(term()) :: WorkflowRun.t() | nil
  def get_run(id), do: Repo.get(WorkflowRun, id)

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
    |> broadcast_run()
  end

  @doc """
  Snapshots the current step state into `log_summary` on the run.

  Called by `StepRunner` after every terminal step transition so the summary
  reflects live progress rather than only the final outcome.
  """
  @spec tick_log_summary(binary()) :: :ok
  def tick_log_summary(run_id) when is_binary(run_id) do
    step_runs = list_step_runs(run_id)

    failed_steps =
      step_runs
      |> Enum.filter(&(&1.status == "failed"))
      |> Enum.map(& &1.step_name)

    log_summary = %{
      step_count: length(step_runs),
      failed_step_count: length(failed_steps),
      failed_steps: failed_steps,
      timeline:
        Enum.map(step_runs, fn sr ->
          %{
            step_name: sr.step_name,
            step_index: sr.step_index,
            status: sr.status,
            started_at: sr.started_at,
            finished_at: sr.finished_at,
            logs: sr.logs || []
          }
        end)
    }

    from(r in WorkflowRun, where: r.id == ^run_id)
    |> Repo.update_all(set: [log_summary: log_summary])

    :ok
  end

  @doc """
  Lists runs for a workflow, ordered by insertion time descending.

  Accepts `limit:` and `offset:` opts for pagination. When omitted, all runs
  are returned.
  """
  @spec list_runs(term(), keyword()) :: [WorkflowRun.t()]
  def list_runs(workflow_id, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from r in WorkflowRun,
        where: r.workflow_id == ^workflow_id,
        order_by: [desc: r.inserted_at, desc: r.id]

    query = if limit, do: from(r in query, limit: ^limit, offset: ^offset), else: query
    Repo.all(query)
  end

  @doc "Returns the total number of runs for a workflow."
  @spec count_runs(term()) :: non_neg_integer()
  def count_runs(workflow_id) do
    Repo.one(from r in WorkflowRun, where: r.workflow_id == ^workflow_id, select: count(r.id))
  end

  @doc """
  Returns all runs stuck in a non-terminal state that can never resume on their
  own — `"running"` and `"pending"`.

  Used by `StartupRecovery` on engine boot to find runs orphaned by a previous
  node shutdown.
  """
  @spec list_stale_runs(keyword()) :: [WorkflowRun.t()]
  def list_stale_runs(_opts \\ []) do
    Repo.all(from r in WorkflowRun, where: r.status in ["running", "pending"])
  end

  @doc """
  Marks a workflow run as `"interrupted"` — the node restarted while it was
  executing.

  Idempotent: returns `{:ok, run}` immediately if the run is already in a
  terminal state (`completed`, `failed`, `cancelled`, `interrupted`).

  In a single transaction:
  - Sets run `status: "interrupted"` and `finished_at`.
  - Bulk-marks any in-flight `StepRun` rows (`status: "running"`) as `"failed"`
    with a `node_shutdown` error.

  After commit, dispatches a `"run.interrupted"` event (fire-and-forget).
  """
  @spec interrupt_run(WorkflowRun.t(), keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, Ecto.Changeset.t()}
  def interrupt_run(%WorkflowRun{} = run, _opts \\ []) do
    if run.status in ["completed", "failed", "cancelled", "interrupted"] do
      {:ok, run}
    else
      now = DateTime.utc_now(:second)

      result =
        Repo.transaction(fn ->
          {:ok, interrupted_run} =
            update_run(run, %{status: "interrupted", finished_at: now})

          from(sr in StepRun,
            where: sr.workflow_run_id == ^run.id and sr.status == "running"
          )
          |> Repo.update_all(
            set: [
              status: "failed",
              errors: %{reason: "node_shutdown", message: "Server restarted during execution"},
              finished_at: now,
              updated_at: now
            ]
          )

          interrupted_run
        end)

      case result do
        {:ok, interrupted_run} ->
          node_router().dispatch(
            Zaq.Event.new(
              %{
                action: "run.interrupted",
                run_id: interrupted_run.id,
                workflow_id: interrupted_run.workflow_id
              },
              :engine,
              name: :workflow
            )
          )

          {:ok, interrupted_run}

        error ->
          error
      end
    end
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
    |> broadcast_step()
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
    |> broadcast_step()
  end

  @doc "Marks a step run as failed, recording the error map, optional logs, and finished_at."
  @spec fail_step_run(StepRun.t(), map(), [map()], keyword()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}
  def fail_step_run(%StepRun{} = step_run, errors, logs \\ [], opts \\ []) do
    step_run
    |> StepRun.changeset(%{
      status: Keyword.get(opts, :status, "failed"),
      errors: errors,
      logs: logs,
      finished_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
    |> broadcast_step()
  end

  @doc "Marks a step run as skipped when a condition evaluated to false."
  @spec skip_step_run(StepRun.t(), map(), [map()], keyword()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}
  def skip_step_run(%StepRun{} = step_run, metadata \\ %{}, logs \\ [], _opts \\ []) do
    step_run
    |> StepRun.changeset(%{
      status: "skipped",
      results: metadata,
      logs: logs,
      finished_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
    |> broadcast_step()
  end

  @doc "Marks a step run as waiting, suspending it pending human approval."
  @spec wait_step_run(StepRun.t(), [map()], keyword()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}
  def wait_step_run(%StepRun{} = step_run, logs \\ [], _opts \\ []) do
    step_run
    |> StepRun.changeset(%{status: "waiting", logs: logs})
    |> Repo.update()
    |> broadcast_step()
  end

  # --- Approval lifecycle ---

  @doc "Creates a StepApproval record for a human-in-the-loop step."
  @spec create_approval(map(), keyword()) ::
          {:ok, StepApproval.t()} | {:error, Ecto.Changeset.t()}
  def create_approval(attrs, _opts \\ []) do
    %StepApproval{}
    |> StepApproval.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Returns a StepApproval by its unique token, or nil."
  @spec get_approval_by_token(String.t(), keyword()) :: StepApproval.t() | nil
  def get_approval_by_token(token, _opts \\ []) do
    Repo.get_by(StepApproval, approval_token: token)
  end

  @doc "Returns the pending StepApproval for a run, or nil."
  @spec get_pending_approval(binary(), keyword()) :: StepApproval.t() | nil
  def get_pending_approval(run_id, _opts \\ []) do
    Repo.get_by(StepApproval, workflow_run_id: run_id, status: "pending")
  end

  @doc """
  Approves a waiting workflow run, completing the approval step and resuming execution.

  Looks up the pending `StepApproval` for the run and the `"waiting"` StepRun,
  marks both as completed/approved in a transaction, transitions the run to `"paused"`,
  then calls `resume_run/2`. The approval data flows to downstream steps via
  StepRunner's resume idempotency cache.

  Returns `{:error, :not_waiting}` if the run is not in `"waiting"` state.
  Returns `{:error, :already_decided}` if the approval has already been acted on.
  """
  @spec approve_step(WorkflowRun.t(), StepApproval.t(), map(), String.t() | nil, keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, :not_waiting | :already_decided | term()}
  def approve_step(
        %WorkflowRun{} = run,
        %StepApproval{} = approval,
        decision,
        approved_by,
        _opts \\ []
      ) do
    with :ok <- validate_run_waiting(run),
         :ok <- validate_approval_pending(approval) do
      Repo.transaction(fn ->
        now = DateTime.utc_now(:second)

        {:ok, _} =
          approval
          |> StepApproval.changeset(%{
            status: "approved",
            decision: decision,
            approved_by: approved_by,
            approved_at: now
          })
          |> Repo.update()

        results = %{approved: true, decision: decision, approved_by: approved_by}
        complete_waiting_step(run.id, approval.step_name, results)
        {:ok, paused_run} = update_run(run, %{status: "paused"})
        paused_run
      end)
      |> case do
        {:ok, paused_run} -> resume_run(paused_run)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Rejects a waiting workflow run, failing the approval step and the run.

  Returns `{:error, :not_waiting}` if the run is not in `"waiting"` state.
  Returns `{:error, :already_decided}` if the approval has already been acted on.
  """
  @spec reject_step(WorkflowRun.t(), StepApproval.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, WorkflowRun.t()} | {:error, :not_waiting | :already_decided | term()}
  def reject_step(
        %WorkflowRun{} = run,
        %StepApproval{} = approval,
        reason,
        approved_by,
        _opts \\ []
      ) do
    with :ok <- validate_run_waiting(run),
         :ok <- validate_approval_pending(approval) do
      Repo.transaction(fn ->
        now = DateTime.utc_now(:second)

        {:ok, _} =
          approval
          |> StepApproval.changeset(%{
            status: "rejected",
            approved_by: approved_by,
            approved_at: now
          })
          |> Repo.update()

        fail_waiting_step(run.id, approval.step_name, reason)

        step_runs = list_step_runs(run.id)
        log_summary = build_rejection_log_summary(step_runs, approval.step_name, reason)

        {:ok, failed_run} =
          update_run(run, %{
            status: "failed",
            finished_at: now,
            log_summary: log_summary
          })

        failed_run
      end)
      |> case do
        {:ok, failed_run} -> {:ok, failed_run}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp complete_waiting_step(run_id, step_name, results) do
    case Repo.get_by(StepRun, workflow_run_id: run_id, step_name: step_name, status: "waiting") do
      %StepRun{step_index: waiting_index} = step_run ->
        prior_cascade = rebuild_cascade_before(run_id, waiting_index)
        cascaded = Map.put(results, :__cascade__, Map.put(prior_cascade, step_name, results))
        {:ok, _} = complete_step_run(step_run, cascaded)

      nil ->
        :ok
    end
  end

  # Reads the most recent completed step before `step_index` and returns its
  # accumulated cascade. Each completed action step stores its full cumulative
  # cascade, so the most recent one holds all prior step data.
  #
  # Edge guard steps share their source action's `step_index` but complete with
  # empty results (no `__cascade__`). Selecting strictly by `step_index` would
  # tie an action with its outgoing edge and pick non-deterministically, dropping
  # the cascade when the edge wins. Instead, scan completed steps newest-first
  # and take the first that actually carries a cascade.
  defp rebuild_cascade_before(run_id, step_index) do
    from(sr in StepRun,
      where:
        sr.workflow_run_id == ^run_id and sr.step_index < ^step_index and
          sr.status == "completed",
      order_by: [desc: sr.step_index, desc: sr.inserted_at]
    )
    |> Repo.all()
    |> Enum.find_value(%{}, fn
      %StepRun{results: r} when is_map(r) ->
        Map.get(r, "__cascade__", Map.get(r, :__cascade__))

      _ ->
        nil
    end)
  end

  defp fail_waiting_step(run_id, step_name, reason) do
    case Repo.get_by(StepRun, workflow_run_id: run_id, step_name: step_name, status: "waiting") do
      %StepRun{} = step_run ->
        {:ok, _} = fail_step_run(step_run, %{rejected: true, reason: reason})

      nil ->
        :ok
    end
  end

  defp validate_run_waiting(%WorkflowRun{status: "waiting"}), do: :ok
  defp validate_run_waiting(_), do: {:error, :not_waiting}

  defp validate_approval_pending(%StepApproval{status: "pending"}), do: :ok
  defp validate_approval_pending(_), do: {:error, :already_decided}

  @doc "Returns the first Step.Run for a run with the given step name, or nil."
  @spec get_step_run_by_name(binary(), String.t(), keyword()) :: StepRun.t() | nil
  def get_step_run_by_name(run_id, step_name, _opts \\ []) do
    Repo.get_by(StepRun, workflow_run_id: run_id, step_name: step_name)
  end

  @doc "Returns the completed StepRun for a given run and step name, or nil."
  @spec get_completed_step_run(binary(), String.t(), keyword()) :: StepRun.t() | nil
  def get_completed_step_run(run_id, step_name, _opts \\ []) do
    Repo.get_by(StepRun, workflow_run_id: run_id, step_name: step_name, status: "completed")
  end

  @doc "Returns the most recent terminal StepRun (completed/failed/skipped/waiting) for a step, or nil."
  @spec get_terminal_step_run(binary(), String.t()) :: StepRun.t() | nil
  def get_terminal_step_run(run_id, step_name) do
    Repo.one(
      from sr in StepRun,
        where:
          sr.workflow_run_id == ^run_id and sr.step_name == ^step_name and
            sr.status in ["completed", "failed", "skipped", "waiting"],
        order_by: [desc: sr.inserted_at],
        limit: 1
    )
  end

  @doc """
  Returns all step runs for a workflow run, ordered by step_index ascending.

  Used by `WorkflowRunAgent` on boot to rehydrate:
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

  @doc """
  Returns `{node, count, cap}` if the run failed because a `map` node tripped its
  D-A8 `max_items` cap, else `nil`.

  Reads the failed aggregate `StepRun` written by the map extract guard
  (`DagBuilder` records it). Used by the agent to surface
  `{:error, {:map_over_limit, …}}` to the run caller. Lives here (not in
  `DagBuilder`) because it is a run-introspection query, not DAG construction.
  """
  @spec map_over_limit(binary()) :: {String.t(), non_neg_integer(), pos_integer()} | nil
  def map_over_limit(run_id) do
    run_id
    |> list_step_runs()
    |> Enum.find_value(fn sr ->
      with %{} = errors <- sr.errors,
           "map_over_limit" <- Map.get(errors, "code") do
        {sr.step_name, Map.get(errors, "count"), Map.get(errors, "cap")}
      else
        _ -> nil
      end
    end)
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

  defp build_rejection_log_summary(step_runs, rejected_step, reason) do
    %{
      step_count: length(step_runs),
      failed_step_count: 1,
      failed_steps: [rejected_step],
      rejection_reason: reason,
      timeline:
        Enum.map(step_runs, fn sr ->
          %{
            step_name: sr.step_name,
            step_index: sr.step_index,
            status: sr.status,
            started_at: sr.started_at,
            finished_at: sr.finished_at,
            logs: sr.logs || []
          }
        end)
    }
  end

  defp duration_ms(nil, _), do: nil
  defp duration_ms(_, nil), do: nil

  defp duration_ms(%DateTime{} = start, %DateTime{} = finish),
    do: DateTime.diff(finish, start, :millisecond)

  # --- Triggers ---

  @doc """
  Returns all triggers, each paired with its linked workflows and the last
  `limit` runs per workflow (default 5), ordered by trigger `inserted_at` desc.

  Returns `[{trigger, [%{workflow: w, recent_runs: [run]}]}]`.
  Uses two bulk queries — no N+1.
  """
  @spec list_triggers_with_workflows_and_recent_runs(keyword()) ::
          [{Trigger.t(), [%{workflow: Workflow.t(), recent_runs: [WorkflowRun.t()]}]}]
  def list_triggers_with_workflows_and_recent_runs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    triggers =
      Repo.all(from t in Trigger, order_by: [desc: t.inserted_at])
      |> Repo.preload(:workflows)

    workflow_ids =
      triggers
      |> Enum.flat_map(& &1.workflows)
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    runs_by_workflow =
      if workflow_ids == [] do
        %{}
      else
        Repo.all(
          from r in WorkflowRun,
            where: r.workflow_id in ^workflow_ids,
            order_by: [desc: r.inserted_at]
        )
        |> Enum.group_by(& &1.workflow_id)
        |> Map.new(fn {wf_id, runs} -> {wf_id, Enum.take(runs, limit)} end)
      end

    Enum.map(triggers, fn trigger ->
      enriched =
        Enum.map(trigger.workflows, fn workflow ->
          %{workflow: workflow, recent_runs: Map.get(runs_by_workflow, workflow.id, [])}
        end)

      {trigger, enriched}
    end)
  end

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

  @doc "Gets a trigger by id. Returns nil if not found."
  @spec get_trigger(term()) :: Trigger.t() | nil
  def get_trigger(id) do
    Repo.get(Trigger, id)
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
    with {:ok, trigger} <- %Trigger{} |> Trigger.changeset(attrs) |> Repo.insert() do
      sync_registry(trigger)
      sync_cron_schedule(trigger)
      {:ok, trigger}
    end
  end

  @doc "Updates a trigger."
  @spec update_trigger(Trigger.t(), map(), keyword()) ::
          {:ok, Trigger.t()} | {:error, Ecto.Changeset.t()}
  def update_trigger(%Trigger{} = trigger, attrs, _opts \\ []) do
    with {:ok, updated} <- trigger |> Trigger.changeset(attrs) |> Repo.update() do
      sync_registry(updated)
      sync_cron_schedule(updated)
      {:ok, updated}
    end
  end

  @doc "Deletes a trigger. Cascades to trigger_workflows via FK."
  @spec delete_trigger(Trigger.t(), keyword()) :: {:ok, Trigger.t()} | {:error, term()}
  def delete_trigger(%Trigger{} = trigger, _opts \\ []) do
    with {:ok, deleted} <- Repo.delete(trigger) do
      sync_cron_schedule_delete(deleted)
      {:ok, deleted}
    end
  end

  @doc """
  Registers all enabled cron triggers with `Zaq.Oban.DynamicCron`.

  Called once at application startup (after Oban is ready) to restore in-memory
  schedules that were lost on restart. Safe to call multiple times — `DynamicCron`
  is idempotent per trigger id key.
  """
  @spec load_cron_triggers(keyword()) :: :ok
  def load_cron_triggers(_opts \\ []) do
    Repo.all(
      from t in Trigger,
        where: t.trigger_type == "cron" and t.enabled == true
    )
    |> Enum.each(&sync_cron_schedule/1)

    :ok
  end

  defp sync_registry(%Trigger{event_name: name, enabled: true}) do
    if Process.whereis(EventRegistry), do: EventRegistry.activate(name)
    :ok
  end

  defp sync_registry(%Trigger{event_name: name, enabled: false}) do
    if Process.whereis(EventRegistry), do: EventRegistry.deactivate(name)
    :ok
  end

  # Registers or replaces a cron trigger's DynamicCron schedule.
  # For non-cron or disabled triggers, removes any existing schedule.
  defp sync_cron_schedule(%Trigger{trigger_type: "cron", enabled: true} = trigger) do
    DynamicCron.replace_schedule(
      "cron_trigger:#{trigger.id}",
      [{trigger.cron_schedule, CronTriggerWorker, [args: %{"trigger_id" => trigger.id}]}]
    )
  catch
    :exit, _ -> :ok
  end

  defp sync_cron_schedule(%Trigger{id: id}) do
    DynamicCron.remove_schedule("cron_trigger:#{id}")
  catch
    :exit, _ -> :ok
  end

  defp sync_cron_schedule_delete(%Trigger{trigger_type: "cron", id: id}) do
    DynamicCron.remove_schedule("cron_trigger:#{id}")
  catch
    :exit, _ -> :ok
  end

  defp sync_cron_schedule_delete(%Trigger{}), do: :ok

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

  # NOTE (Part 3, Step 7): the legacy `broadcast_batch_progress/3` and
  # `broadcast_iterate_progress/3` helpers were removed. The `map` model writes a
  # real per-fork `StepRun` per item, each broadcast live as `{:step_updated, _}`
  # via `broadcast_step/1`, with the aggregate map row as the final "all done"
  # event. That is strictly more visibility than the old per-chunk progress
  # tuples, which only existed because Batch/Iterate ran as one opaque step.

  defp node_router, do: Application.get_env(:zaq, :node_router, Zaq.NodeRouter)

  # Dispatches a `:workflow` lifecycle event (e.g. `run.failed`) via NodeRouter.
  # Mirrors the agent's lifecycle dispatch; used here for the build-failure path
  # in `ensure_prepared_dag/1`, which the agent no longer owns.
  defp dispatch_workflow_event(action, body) do
    Map.put(body, :action, action)
    |> Zaq.Event.new(:engine, name: :workflow)
    |> node_router().dispatch()
  end

  # Renders a DAG build error into a human-readable run `log_summary` message.
  # Reachable only via code drift (save-time validation rejects unrunnable
  # workflows); kept for operator-facing clarity on those rare runs.
  defp format_build_error(:invalid_steps),
    do: "Workflow steps configuration is invalid or missing."

  defp format_build_error(:empty_dag),
    do: "Workflow has no nodes configured."

  defp format_build_error({:unknown_node_type, type}),
    do: "Unknown node type \"#{type}\". Expected \"action\" or \"agent\"."

  defp format_build_error({:unknown_module, nil}),
    do: "A node is missing its module configuration."

  defp format_build_error({:unknown_module, mod}),
    do: "Module not found: \"#{mod}\". Check that the module name is spelled correctly."

  defp format_build_error({:unknown_node, name}),
    do: "An edge references node \"#{name}\" which does not exist."

  defp format_build_error({:invalid_edge_condition, _}),
    do: "An edge has an invalid condition configuration."

  defp format_build_error({:contract_violation, mod, missing}),
    do:
      "Module #{inspect(mod)} does not satisfy the Action contract. Missing: #{inspect(missing)}."

  defp format_build_error(reason),
    do: inspect(reason)

  # Fans a workflow UI broadcast out through the Channels role instead of touching
  # `Phoenix.PubSub` from the engine context. Channels owns the real re-broadcast
  # (see `Zaq.Channels.Api` `:broadcast`), so BO LiveView subscribers receive the
  # same topic/message. Dispatched async — broadcasting is fire-and-forget and must
  # never block or fail the run lifecycle.
  defp dispatch_async(topic, message) when is_binary(topic) do
    Zaq.Event.new({:broadcast, topic, message}, :channels,
      type: :async,
      opts: [action: :broadcast]
    )
    |> node_router().dispatch()

    :ok
  end

  @doc """
  Re-broadcasts the current state of a run to its `workflow_run:<run_id>`
  subscribers as `{:run_updated, run}`.

  Loads the run by id and owns the workflow-run topic/message convention so
  callers (e.g. the engine boundary on lifecycle status events) need not reach
  into PubSub or the `WorkflowRun` struct themselves. No-ops when the run is
  missing.
  """
  def broadcast_run_update(run_id) do
    case get_run(run_id) do
      %WorkflowRun{} = run ->
        dispatch_async("workflow_run:#{run_id}", {:run_updated, run})

      _ ->
        :ok
    end
  end

  defp broadcast_run({:ok, run} = result) do
    dispatch_async("workflow_run:#{run.id}", {:run_updated, run})

    if run.status in ["completed", "failed", "cancelled"] do
      dispatch_async("workflow:#{run.workflow_id}", {:run_finished, run})
    end

    result
  end

  defp broadcast_run(result), do: result

  defp broadcast_step({:ok, step_run} = result) do
    normalized = %{step_run | logs: stringify_log_keys(step_run.logs)}
    dispatch_async("workflow_run:#{step_run.workflow_run_id}", {:step_updated, normalized})
    result
  end

  defp broadcast_step(result), do: result

  # Repo.update/1 returns the struct with atom-keyed log maps (as passed to the
  # changeset), whereas Repo.all/1 deserializes JSONB with string keys.  Normalize
  # before broadcasting so real-time subscribers see the same shape as page-load data.
  defp stringify_log_keys(nil), do: []

  defp stringify_log_keys(logs) do
    Enum.map(logs, fn log ->
      Map.new(log, fn {k, v} -> {to_string(k), v} end)
    end)
  end
end
