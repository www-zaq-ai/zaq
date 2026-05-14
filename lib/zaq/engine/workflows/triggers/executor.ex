defmodule Zaq.Engine.Workflows.Trigger.Executor do
  @moduledoc """
  Orchestrates workflow dispatch for a trigger.

  Given a trigger (preloaded with `:downstream_triggers`), `execute/3`:

  1. Calls `trigger_module.fire/2` to build the source event.
  2. Loads assigned workflows in position order and dispatches them according to
     the trigger's `execution_mode`:
     - `:parallel` — all workflows dispatched concurrently via `Task.async_stream`,
       capped at `max_concurrency`. All run to completion regardless of failures.
     - `:serial`   — workflows run in position order. `on_failure: :stop` halts on
       the first failure; `on_failure: :continue` runs all regardless.
  3. After own workflows complete, fires all `downstream_triggers` unconditionally
     (regardless of own workflow outcomes).

  Returns `{:ok, results}` where `results` is a flat list of
  `{workflow_id, {:ok, run} | {:error, reason}}` tuples covering both own
  workflows and those dispatched by downstream triggers.
  """

  require Logger

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Trigger

  @type result :: {binary(), {:ok, term()} | {:error, term()}}

  @spec execute(Trigger.t(), map(), keyword()) :: {:ok, [result()]}
  def execute(%Trigger{} = trigger, input, opts \\ []) do
    trigger = ensure_downstream_preloaded(trigger)

    case Trigger.module(trigger) do
      {:ok, mod} ->
        with {:ok, event} <- mod.fire(trigger, input) do
          own_results = dispatch_workflows(trigger, event)
          downstream_results = fire_downstream(trigger.downstream_triggers, input, opts)
          {:ok, own_results ++ downstream_results}
        end

      {:error, :unknown_type} ->
        {:error, {:unknown_trigger_type, trigger.type}}
    end
  end

  defp ensure_downstream_preloaded(%Trigger{downstream_triggers: triggers} = t)
       when is_list(triggers),
       do: t

  defp ensure_downstream_preloaded(%Trigger{} = trigger),
    do: Zaq.Repo.preload(trigger, :downstream_triggers)

  defp dispatch_workflows(%Trigger{execution_mode: :parallel} = trigger, event) do
    workflows = Workflows.list_workflows_for_trigger(trigger)

    stream_opts =
      [on_timeout: :kill_task, ordered: false] ++
        if trigger.max_concurrency, do: [max_concurrency: trigger.max_concurrency], else: []

    workflows
    |> Task.async_stream(
      fn workflow -> {workflow.id, run_workflow(workflow, event)} end,
      stream_opts
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {nil, {:error, {:task_exit, reason}}}
    end)
  end

  defp dispatch_workflows(%Trigger{execution_mode: :serial} = trigger, event) do
    workflows = Workflows.list_workflows_for_trigger(trigger)

    {results, _halted} =
      Enum.reduce(workflows, {[], false}, fn
        _workflow, {acc, true} ->
          {acc, true}

        workflow, {acc, false} ->
          outcome = {workflow.id, run_workflow(workflow, event)}

          halt =
            trigger.on_failure == :stop and
              match?({_, {:error, _}}, outcome)

          {[outcome | acc], halt}
      end)

    Enum.reverse(results)
  end

  defp run_workflow(workflow, event) do
    with {:ok, run} <- Workflows.create_run(workflow, event) do
      Workflows.start_run(run)
    end
  end

  defp fire_downstream([], _input, _opts), do: []

  defp fire_downstream(downstream_triggers, input, opts) do
    downstream_triggers
    |> Task.async_stream(
      fn trigger ->
        {:ok, results} = execute(trigger, input, opts)
        results
      end,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, results} -> results
      _ -> []
    end)
  end
end
