defmodule Zaq.Engine.Workflows.WorkflowRunAgent do
  @moduledoc """
  Executes a `WorkflowRun` by running its pre-built instrumented Runic DAG
  synchronously to completion.

  This module **only runs** a DAG — it never builds one. The run module
  (`Workflows.ensure_prepared_dag/1`) attaches an executable DAG to
  `run.prepared_dag` before `start_run/2` / `resume_run/2` hand the run here;
  `execute/2` returns `{:error, :missing_prepared_dag}` if it ever receives a run
  without one. Build failures (and the operator-facing error rendering) are the
  run module's responsibility, not this module's.

  ## Execution flow

  1. Reads the prepared DAG from `run.prepared_dag` (each action node is already
     wrapped in `StepRunner`, which writes one `StepRun` row per step:
     running → completed/failed).
  2. Transitions the run to `"running"`.
  3. Extracts the initial fact from `run.source_event.assigns[:input]` (or string
     key equivalent after a JSONB round-trip), defaulting to `%{}` if absent. The
     event-envelope structural keys (`:event`, and within it `:name`, `:trace_id`,
     `:payload`, `:assigns`) are normalized to atoms at this single point so action
     authors always read `params.event.payload` with atom keys regardless of
     whether the run was reloaded from the DB. Arbitrary payload/assigns values are
     preserved verbatim. Feeds this as the initial fact into
     `Runic.Workflow.react_until_satisfied/3`.
  4. After execution, checks `StepRun` rows: any `"failed"` row → run becomes
     `"failed"`, otherwise `"completed"`.

  ## Pause / Resume

  A `:checkpoint` function is passed to `react_until_satisfied/3`. After each
  react cycle it re-reads the `WorkflowRun` row; if the status is `"paused"` it
  throws `:pause_requested`, which is caught and returned as `{:ok, paused_run}`.
  To resume, call `Workflows.resume_run/2` — `StepRunner` skips completed steps
  so execution continues from the first incomplete step.

  ## Crash safety

  If a step raises, `StepRunner` marks its `StepRun` row as `"failed"` before
  re-raising. `finalize/2` treats any `"running"` or `"failed"` rows as failures and
  marks the run accordingly. Unexpected crashes in Runic itself propagate naturally
  to the caller — they are not silently swallowed.

  ## Lifecycle Events

  Dispatches the following `:workflow` events via `NodeRouter`:

  | Action | When |
  |---|---|
  | `"run.started"` | After run is transitioned to `"running"` |
  | `"run.completed"` | After `finalize/2` marks the run `"completed"` |
  | `"run.failed"` | After `finalize/2` marks the run `"failed"` (a *build* failure emits `run.failed` from the run module, before this module runs) |

  All events carry `%{action: action, run_id: id, workflow_id: wid}` in `request`.
  Dispatch is fire-and-forget — failures do not affect run state.

  ## Usage

      {:ok, run} = Zaq.Engine.Workflows.start_run(run)
  """

  require Logger

  alias Runic.Workflow
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRun
  alias Zaq.Event

  @spec execute(WorkflowRun.t(), keyword()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def execute(run, opts \\ [])

  # The run must already carry an executable DAG — the run module
  # (`Workflows.ensure_prepared_dag/1`) builds it before start/resume. This
  # defensive clause should never fire on the start/resume paths.
  def execute(%WorkflowRun{prepared_dag: nil}, _opts), do: {:error, :missing_prepared_dag}

  def execute(%WorkflowRun{prepared_dag: dag} = run, _opts) do
    Registry.register(Zaq.Engine.Workflows.RunRegistry, run.id, self())

    now = DateTime.utc_now(:second)
    started_ms = System.monotonic_time(:millisecond)

    Logger.info("[workflow] run started",
      workflow_id: run.workflow_id,
      run_id: run.id,
      trigger_type: run.source_event && fetch_trigger_type(run.source_event.assigns)
    )

    start_attrs =
      if run.started_at, do: %{status: "running"}, else: %{status: "running", started_at: now}

    case workflows_mod().update_run(run, start_attrs) do
      {:ok, run} ->
        dispatch_workflow_event("run.started", %{run_id: run.id, workflow_id: run.workflow_id})
        execute_dag_with_pause(dag, run, started_ms)

      {:error, reason} ->
        Logger.error("[workflow] run failed to start",
          workflow_id: run.workflow_id,
          run_id: run.id,
          error: inspect(reason)
        )

        workflows_mod().update_run(run, %{
          status: "failed",
          finished_at: DateTime.utc_now(:second)
        })

        {:error, reason}
    end
  end

  defp execute_dag_with_pause(dag, %WorkflowRun{} = run, started_ms) do
    input = fetch_input(run.source_event)
    checkpoint = fn _workflow -> pause_checkpoint!(run.id) end

    try do
      # Run-driver mode: SEQUENTIAL today. `react_until_satisfied/3` also accepts
      # `async: true, max_concurrency:, timeout:` to fan map forks out across
      # processes, but we intentionally do NOT thread them yet — sequential
      # execution keeps the map summary order deterministic (forks resolve in
      # index order). Enabling async additionally requires per-fork names that
      # cannot collide and `FanIn` `mergeable` accumulation; when enabling, pass
      # the opts here and re-confirm ordering.
      Workflow.react_until_satisfied(dag, input, checkpoint: checkpoint)
      result = finalize(run, started_ms)

      # Guard: a `map` node whose collection exceeded its `max_items` cap
      # writes a failed StepRun (so `finalize/2` already marked the run "failed")
      # and skips its downstream fan-out via Runic. Surface the precise reason to
      # the caller rather than a generic failed run.
      case Workflows.map_over_limit(run.id) do
        {node, count, cap} -> {:error, {:map_over_limit, node, count, cap}}
        nil -> result
      end
    catch
      :throw, :pause_requested ->
        Logger.info("[workflow] run paused", run_id: run.id)
        {:ok, Workflows.get_run!(run.id)}
    end
  end

  defp pause_checkpoint!(run_id) do
    case Workflows.get_run!(run_id) do
      %WorkflowRun{status: "paused"} -> throw(:pause_requested)
      _ -> :ok
    end
  end

  defp finalize(%WorkflowRun{} = run, started_ms) do
    step_runs = Workflows.list_step_runs(run.id)
    duration_ms = System.monotonic_time(:millisecond) - started_ms

    cond do
      # A "waiting" StepRun means a HumanInTheLoop step suspended execution.
      # StepRunner already marked the StepRun; we transition the run here.
      Enum.any?(step_runs, &(&1.status == "waiting")) ->
        Logger.info("[workflow] run waiting for human approval",
          workflow_id: run.workflow_id,
          run_id: run.id,
          duration_ms: duration_ms
        )

        result = Workflows.update_run(run, %{status: "waiting"})
        dispatch_workflow_event("run.waiting", %{run_id: run.id, workflow_id: run.workflow_id})
        result

      # A row stuck at "running" after execution means the action raised and
      # never updated itself — treat it as a failure (crash cursor).
      # `failed_fatal` rows (isolated per-fork `map` failures under
      # :skip_and_continue/:retry) are recorded for visibility but never fail the
      # run — they are not in this list, so the aggregate map row carries the
      # run-relevant status.
      Enum.any?(step_runs, &(&1.status in ["failed", "running"])) ->
        failed_steps =
          step_runs
          |> Enum.filter(&(&1.status in ["failed", "running"]))
          |> Enum.map(& &1.step_name)

        log_summary = build_log_summary(step_runs, failed_steps, duration_ms)

        Logger.error("[workflow] run failed",
          workflow_id: run.workflow_id,
          run_id: run.id,
          failed_steps: failed_steps,
          duration_ms: duration_ms
        )

        result =
          Workflows.update_run(run, %{
            status: "failed",
            finished_at: DateTime.utc_now(:second),
            log_summary: log_summary
          })

        dispatch_workflow_event("run.failed", %{run_id: run.id, workflow_id: run.workflow_id})
        result

      true ->
        log_summary = build_log_summary(step_runs, [], duration_ms)

        Logger.info("[workflow] run completed",
          workflow_id: run.workflow_id,
          run_id: run.id,
          step_count: length(step_runs),
          duration_ms: duration_ms
        )

        result =
          Workflows.update_run(run, %{
            status: "completed",
            finished_at: DateTime.utc_now(:second),
            log_summary: log_summary
          })

        dispatch_workflow_event("run.completed", %{run_id: run.id, workflow_id: run.workflow_id})
        result
    end
  end

  defp build_log_summary(step_runs, failed_steps, duration_ms) do
    %{
      step_count: length(step_runs),
      failed_step_count: length(failed_steps),
      failed_steps: failed_steps,
      duration_ms: duration_ms,
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

  # Safely fetch the input from assigns, handling both atom and string keys
  # (JSONB round-trip converts atom keys to strings). The resolved input is
  # normalized to atom keys at this single point so action authors always see
  # `params.event.payload` as atoms, independent of whether the run was
  # reloaded from the DB (synchronous path keeps atoms; reloaded path is
  # deeply string-keyed by JSONB).
  defp fetch_input(source_event) when is_nil(source_event), do: %{}

  defp fetch_input(source_event) do
    assigns = source_event.assigns || %{}

    (Zaq.MapUtils.fetch_either(assigns, :input, "input") || %{})
    |> normalize_input()
  end

  # Normalizes only the known event-envelope structural keys to atoms. Arbitrary
  # payload/assigns values are preserved verbatim. No dynamic atom creation
  # (atom-exhaustion safe) — only the fixed keys this module controls.
  defp normalize_input(input) when is_map(input) do
    case Zaq.MapUtils.fetch_either(input, :event, "event") do
      event_map when is_map(event_map) ->
        input
        |> Map.drop([:event, "event"])
        |> Map.put(:event, normalize_event(event_map))

      _ ->
        input
    end
  end

  defp normalize_input(input), do: input

  defp normalize_event(event_map) do
    %{
      name: Zaq.MapUtils.fetch_either(event_map, :name, "name"),
      trace_id: Zaq.MapUtils.fetch_either(event_map, :trace_id, "trace_id"),
      payload: Zaq.MapUtils.fetch_either(event_map, :payload, "payload"),
      assigns: Zaq.MapUtils.fetch_either(event_map, :assigns, "assigns") || %{}
    }
  end

  # Safely fetch trigger_type from assigns, handling both atom and string keys.
  defp fetch_trigger_type(assigns) do
    Zaq.MapUtils.fetch_either(assigns, :trigger_type, "trigger_type")
  end

  defp dispatch_workflow_event(action, body) do
    event = Event.new(Map.put(body, :action, action), :engine, name: :workflow)
    node_router().dispatch(event)
  end

  defp node_router, do: Application.get_env(:zaq, :node_router, Zaq.NodeRouter)

  defp workflows_mod,
    do: Application.get_env(:zaq, :workflow_run_agent_workflows_mod, Workflows)
end
