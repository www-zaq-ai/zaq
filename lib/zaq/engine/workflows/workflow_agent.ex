defmodule Zaq.Engine.Workflows.WorkflowAgent do
  @moduledoc """
  Executes a `WorkflowRun` by building its instrumented Runic DAG and running it
  synchronously to completion.

  ## Execution flow

  1. Transitions the run to `"running"`.
  2. Builds the DAG from `run.steps_snapshot` with `DagBuilder.build/2`, passing
     `run_id:` so every action node is wrapped in `ActionWrapper`. ActionWrapper
     writes one `StepRun` row per step (running → completed/failed).
  3. Extracts the initial fact from `run.source_event.assigns[:input]` (or string
     key equivalent after a JSONB round-trip), defaulting to `%{}` if absent. The
     event-envelope structural keys (`:event`, and within it `:name`, `:trace_id`,
     `:payload`, `:assigns`) are normalized to atoms at this single point so action
     authors always read `params.event.payload` with atom keys regardless of
     whether the run was reloaded from the DB. Arbitrary payload/assigns values are
     preserved verbatim. Feeds this as the initial fact into
     `Runic.Workflow.react_until_satisfied/2`.
  4. After execution, checks `StepRun` rows: any `"failed"` row → run becomes
     `"failed"`, otherwise `"completed"`.

  ## Crash safety

  If a step raises, `ActionWrapper` marks its `StepRun` row as `"failed"` before
  re-raising. `finalize/2` treats any `"running"` or `"failed"` rows as failures and
  marks the run accordingly. Unexpected crashes in Runic itself propagate naturally
  to the caller — they are not silently swallowed.

  ## Usage

      {:ok, run} = Zaq.Engine.Workflows.start_run(run)
  """

  require Logger

  alias Runic.Workflow
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.{DagBuilder, WorkflowRun}

  @spec execute(WorkflowRun.t(), keyword()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def execute(%WorkflowRun{} = run, _opts \\ []) do
    now = DateTime.utc_now(:second)
    started_ms = System.monotonic_time(:millisecond)

    Logger.info("[workflow] run started",
      workflow_id: run.workflow_id,
      run_id: run.id,
      trigger_type: run.source_event && fetch_trigger_type(run.source_event.assigns)
    )

    with {:ok, run} <- Workflows.update_run(run, %{status: "running", started_at: now}),
         {:ok, dag} <- DagBuilder.build(run.steps_snapshot, run_id: run.id) do
      input = fetch_input(run.source_event)

      Workflow.react_until_satisfied(dag, input)
      finalize(run, started_ms)
    else
      {:error, reason} ->
        Logger.error("[workflow] run failed to start",
          workflow_id: run.workflow_id,
          run_id: run.id,
          error: inspect(reason)
        )

        Workflows.update_run(run, %{status: "failed", finished_at: DateTime.utc_now(:second)})
        {:error, reason}
    end
  end

  defp finalize(%WorkflowRun{} = run, started_ms) do
    step_runs = Workflows.list_step_runs(run.id)
    finished_at = DateTime.utc_now(:second)
    duration_ms = System.monotonic_time(:millisecond) - started_ms

    # A row stuck at "running" after execution means the action raised and
    # never updated itself — treat it as a failure (crash cursor).
    any_incomplete = Enum.any?(step_runs, &(&1.status in ["failed", "running"]))

    failed_steps =
      step_runs
      |> Enum.filter(&(&1.status in ["failed", "running"]))
      |> Enum.map(& &1.step_name)

    log_summary = %{
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
            finished_at: sr.finished_at
          }
        end)
    }

    if any_incomplete do
      Logger.error("[workflow] run failed",
        workflow_id: run.workflow_id,
        run_id: run.id,
        failed_steps: failed_steps,
        duration_ms: duration_ms
      )

      Workflows.update_run(run, %{
        status: "failed",
        finished_at: finished_at,
        log_summary: log_summary
      })
    else
      Logger.info("[workflow] run completed",
        workflow_id: run.workflow_id,
        run_id: run.id,
        step_count: length(step_runs),
        duration_ms: duration_ms
      )

      Workflows.update_run(run, %{
        status: "completed",
        finished_at: finished_at,
        log_summary: log_summary
      })
    end
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
end
