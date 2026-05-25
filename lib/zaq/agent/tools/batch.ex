defmodule Zaq.Agent.Tools.Batch do
  @moduledoc """
  DAG-level orchestrator that drives a downstream pipeline over a list of items
  in configurable chunks.

  ## How it works

  `DagBuilder` resolves the `process` and `post_process` node lists and injects
  them as `__batch_process__` and `__batch_post_process__` — lists of
  `{module, base_params}` pairs.  It also inspects the input schema of the first
  process action and injects `__batch_field__` (the key to deliver chunk data
  under) and `__batch_mode__` (`:list` or `:item`).

  Per chunk:

  1. **Process** — the process pipeline is called with chunk data delivered in
     the shape the first action declares:
     - `:list` mode → `%{field => [item1, item2, ...]}` (whole chunk at once)
     - `:item` mode → `%{field => item}` called once per item in the chunk;
       per-item results collected as `%{results: [...], errors: [...]}`

  2. **Post-process** — called once per chunk with an empty initial accumulator
     (`base_params` from `DagBuilder` drive the actions).  Useful for rate
     limiting, logging, or any side-effect between chunks.

  3. **Strategy** applied on any error (process or post-process).

  ## Failure strategies

  - `:skip_and_continue` (default) — skip failed chunks, collect errors, always return `:ok`
  - `:fail_workflow` — stop on the first failed chunk and return `{:error, reason}`
  - `:retry` — retry each failing chunk up to 3 total attempts before skipping

  ## ACK model

  Batch is ack-agnostic.  If a process action dispatches async work, it owns its
  own completion semantics (e.g. a `DispatchAndAwait` action that subscribes to
  PubSub internally and blocks until all acknowledgements arrive).  Batch simply
  waits for `run/2` to return.

  ## Output

      %{
        results: [per-chunk process pipeline outputs],
        errors:  [%{index: i, reason: reason} for failed chunks]
      }
  """

  use Jido.Action,
    name: "batch",
    description: "Orchestrates a downstream pipeline over a list of items in chunks.",
    schema: [
      items: [
        type: :list,
        required: true,
        doc: "List of items to process in batches."
      ],
      strategy: [
        type: {:in, [:skip_and_continue, :fail_workflow, :retry]},
        required: false,
        default: :skip_and_continue,
        doc: "Failure strategy: :skip_and_continue (default), :fail_workflow, or :retry."
      ],
      batch_size: [
        type: :pos_integer,
        required: false,
        doc: "Number of items per chunk. Omit to treat each item as its own single-element chunk."
      ],
      process: [
        type: {:list, :any},
        required: true,
        doc: "Injected by DagBuilder. List of {module, base_params} tuples for process pipeline."
      ],
      post_process: [
        type: {:list, :any},
        required: false,
        default: [],
        doc: "Injected by DagBuilder. Runs once per chunk after process completes."
      ],
      __batch_field__: [
        type: :atom,
        required: true,
        doc:
          "Injected by DagBuilder. Key under which chunk data is delivered to process pipeline."
      ],
      __batch_mode__: [
        type: {:in, [:list, :item]},
        required: true,
        doc:
          "Injected by DagBuilder. :list delivers whole chunk; :item delivers one item per call."
      ]
    ],
    output_schema: [
      results: [type: :list, required: true, doc: "Successful pipeline results per chunk."],
      errors: [type: :list, required: true, doc: "Collected errors for failed chunks."]
    ]

  use Zaq.Engine.Workflows.Action

  alias Zaq.Agent.Tools.PipelineRunner

  require Logger

  @max_retries 3

  @impl Jido.Action
  def run(params, context) do
    items = Map.get(params, :items, [])
    strategy = Map.get(params, :strategy, :skip_and_continue)
    process = Map.get(params, :process, [])
    post_process = Map.get(params, :post_process, [])
    field = Map.get(params, :__batch_field__)
    mode = Map.get(params, :__batch_mode__, :list)
    batch_size = Map.get(params, :batch_size)
    on_between = Map.get(context, :on_between)

    chunks = chunk_items(items, batch_size)

    Logger.info("[batch] starting",
      run_id: Map.get(context, :run_id),
      step_name: Map.get(context, :step_name),
      total_items: length(items),
      total_chunks: length(chunks),
      batch_size: batch_size || :per_item,
      strategy: strategy,
      delivery_mode: mode,
      field: field,
      process_steps: length(process),
      post_process_steps: length(post_process)
    )

    result = execute(chunks, process, post_process, field, mode, strategy, context, on_between)

    case result do
      {:ok, %{results: results, errors: errors, logs: logs}} ->
        Logger.info("[batch] complete",
          run_id: Map.get(context, :run_id),
          step_name: Map.get(context, :step_name),
          total_items: length(items),
          total_chunks: length(chunks),
          successful_chunks: length(results),
          failed_chunks: length(errors)
        )

        {:ok, %{results: results, errors: errors}, logs: logs}

      {:error, reason} = err ->
        Logger.warning("[batch] halted — fail_workflow strategy",
          run_id: Map.get(context, :run_id),
          step_name: Map.get(context, :step_name),
          reason: inspect(reason)
        )

        err
    end
  end

  # Always returns plain lists — field wrapping happens at delivery time.
  defp chunk_items(items, nil), do: Enum.map(items, &[&1])
  defp chunk_items(items, size), do: Enum.chunk_every(items, size)

  defp execute(chunks, process, post_process, field, mode, strategy, context, on_between) do
    last_index = length(chunks) - 1

    result =
      chunks
      |> Enum.with_index()
      |> Enum.reduce_while({[], [], []}, fn {chunk, idx}, {results, errors, logs} ->
        outcome = run_chunk(chunk, process, post_process, field, mode, strategy, context)

        Logger.debug("[batch] chunk #{idx + 1}/#{last_index + 1} processed",
          run_id: Map.get(context, :run_id),
          chunk_index: idx,
          chunk_size: length(chunk),
          outcome: elem(outcome, 0)
        )

        step(outcome, strategy, on_between, idx, last_index, results, errors, logs)
      end)

    PipelineRunner.finalize_result(result)
  end

  defp run_chunk(chunk, process, post_process, field, mode, strategy, context) do
    with {:ok, chunk_result, process_logs} <-
           run_process_with_logs(chunk, process, field, mode, strategy, context),
         {:ok, _post_result} <- PipelineRunner.run_pipeline(%{}, post_process, context) do
      {:ok, chunk_result, process_logs}
    end
  end

  # ── Process delivery ──────────────────────────────────────────────────────────

  # Returns {:ok, result, logs} or {:error, reason}. Logs are collected from
  # sub-steps (e.g. Iterate) via run_pipeline_with_logs.
  defp run_process_with_logs(chunk, pipeline, field, :list, strategy, context) do
    delivery = %{field => chunk}
    invoke_with_logs(delivery, pipeline, strategy, context)
  end

  defp run_process_with_logs(chunk, pipeline, field, :item, strategy, context) do
    result =
      chunk
      |> Enum.with_index()
      |> Enum.reduce_while({[], []}, fn {item, idx}, {results, errors} ->
        delivery = %{field => item}
        outcome = PipelineRunner.invoke(delivery, pipeline, strategy, context)
        handle_item_outcome(outcome, strategy, idx, results, errors)
      end)

    case result do
      {:error, reason} ->
        {:error, reason}

      {results, errors} ->
        {:ok, %{results: Enum.reverse(results), errors: Enum.reverse(errors)}, []}
    end
  end

  defp handle_item_outcome({:error, reason}, :fail_workflow, _idx, _results, _errors) do
    {:halt, {:error, reason}}
  end

  defp handle_item_outcome({:ok, value}, _strategy, _idx, results, errors) do
    {:cont, {[value | results], errors}}
  end

  defp handle_item_outcome({:error, reason}, _strategy, idx, results, errors) do
    {:cont, {results, [%{index: idx, reason: reason} | errors]}}
  end

  # ── Chunk-level step / strategy ───────────────────────────────────────────────

  defp step({:error, reason}, :fail_workflow, _on_between, _idx, _last, _r, _e, _logs) do
    {:halt, {:error, reason}}
  end

  defp step({:ok, value, process_logs}, _strategy, on_between, idx, last, results, errors, logs) do
    maybe_fire_between(on_between, idx, last, {:ok, value})
    chunk_log = build_chunk_log(value, process_logs, idx)
    {:cont, {[value | results], errors, [chunk_log | logs]}}
  end

  defp step({:error, reason} = outcome, _strategy, on_between, idx, last, results, errors, logs) do
    maybe_fire_between(on_between, idx, last, outcome)
    chunk_log = %{event: "chunk_error", index: idx, reason: format_reason(reason)}
    {:cont, {results, [%{index: idx, reason: reason} | errors], [chunk_log | logs]}}
  end

  # ── Logs-collecting pipeline runner (for process steps) ──────────────────────

  defp invoke_with_logs(delivery, pipeline, :retry, context),
    do: invoke_with_retry_logs(delivery, pipeline, context, @max_retries)

  defp invoke_with_logs(delivery, pipeline, _strategy, context),
    do: run_pipeline_with_logs(delivery, pipeline, context)

  defp invoke_with_retry_logs(delivery, pipeline, context, retries_left) do
    case run_pipeline_with_logs(delivery, pipeline, context) do
      {:ok, value, logs} ->
        {:ok, value, logs}

      {:error, _} when retries_left > 1 ->
        invoke_with_retry_logs(delivery, pipeline, context, retries_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_pipeline_with_logs(delivery, [], _context), do: {:ok, delivery, []}

  defp run_pipeline_with_logs(delivery, pipeline, context) do
    pipeline
    |> Enum.reduce_while({:ok, delivery, []}, fn {mod, base_params}, {:ok, acc, acc_logs} ->
      case mod.run(Map.merge(base_params, acc), context) do
        {:ok, result} -> {:cont, {:ok, result, acc_logs}}
        {:ok, result, logs: step_logs} -> {:cont, {:ok, result, acc_logs ++ step_logs}}
        {:error, _} = err -> {:halt, {err, acc_logs}}
      end
    end)
    |> case do
      {:ok, result, logs} -> {:ok, result, logs}
      {{:error, reason}, _logs} -> {:error, reason}
    end
  end

  defp build_chunk_log(value, iteration_logs, idx) do
    results = Map.get(value, :results) || Map.get(value, "results")
    errors = Map.get(value, :errors) || Map.get(value, "errors")

    base = %{event: "chunk_completed", index: idx, iteration_logs: iteration_logs}

    if is_list(results) and is_list(errors) do
      Map.merge(base, %{results: length(results), errors: length(errors)})
    else
      base
    end
  end

  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp maybe_fire_between(nil, _idx, _last, _outcome), do: :ok
  defp maybe_fire_between(_cb, idx, last, _outcome) when idx == last, do: :ok
  defp maybe_fire_between(cb, idx, _last, outcome), do: cb.(idx, outcome)
end
