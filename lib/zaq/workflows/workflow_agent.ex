defmodule Zaq.Workflows.WorkflowAgent do
  @moduledoc """
  Executes a `WorkflowRun` by building its instrumented Runic DAG and running it
  synchronously to completion.

  ## Execution flow

  1. Transitions the run to `"running"`.
  2. Builds the DAG from `run.steps_snapshot` with `DagBuilder.build/2`, passing
     `run_id:` so every action node is wrapped in `ActionWrapper`. ActionWrapper
     writes one `ActionResult` row per step (running → completed/failed).
  3. Feeds `run.source_event.assigns` as the initial fact into
     `Runic.Workflow.react_until_satisfied/2`, which executes the DAG inline.
  4. After execution, checks `ActionResult` rows: any `"failed"` row → run becomes
     `"failed"`, otherwise `"completed"`.

  ## Crash safety

  If this process dies mid-execution, the `WorkflowRun` stays at `"running"` and
  any in-flight step stays at `"running"` with no `finished_at`. The agent
  rehydration path (planned in a follow-up) reads these rows to resume.

  ## Usage

      {:ok, run} = Zaq.Workflows.start_run(run)
  """

  alias Runic.Workflow
  alias Zaq.Workflows
  alias Zaq.Workflows.{DagBuilder, WorkflowRun}

  @spec execute(WorkflowRun.t(), keyword()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def execute(%WorkflowRun{} = run, _opts \\ []) do
    now = DateTime.utc_now(:second)

    with {:ok, run} <- Workflows.update_run(run, %{status: "running", started_at: now}),
         {:ok, dag} <- DagBuilder.build(run.steps_snapshot, run_id: run.id) do
      # Use assigns.input (the workflow payload) as the initial fact, not the
      # full assigns map which also contains ZAQ event metadata (trigger_type etc.).
      input =
        (run.source_event && get_in(run.source_event.assigns, [:input])) ||
          (run.source_event && run.source_event.assigns) ||
          %{}

      try do
        Workflow.react_until_satisfied(dag, input)
        finalize(run)
      rescue
        e ->
          Workflows.update_run(run, %{status: "failed", finished_at: DateTime.utc_now(:second)})
          {:error, e}
      end
    else
      {:error, reason} ->
        Workflows.update_run(run, %{status: "failed", finished_at: DateTime.utc_now(:second)})
        {:error, reason}
    end
  end

  defp finalize(%WorkflowRun{} = run) do
    results = Workflows.list_action_results(run.id)
    finished_at = DateTime.utc_now(:second)

    # A row stuck at "running" after execution means the action raised and
    # never updated itself — treat it as a failure (crash cursor).
    any_incomplete = Enum.any?(results, &(&1.status in ["failed", "running"]))

    if any_incomplete do
      Workflows.update_run(run, %{status: "failed", finished_at: finished_at})
    else
      Workflows.update_run(run, %{status: "completed", finished_at: finished_at})
    end
  end
end
