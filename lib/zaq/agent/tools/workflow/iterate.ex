defmodule Zaq.Agent.Tools.Workflow.Iterate do
  @moduledoc """
  Generic per-item pipeline runner — the counterpart to `Batch`.

  `Iterate` receives a list of items and runs a downstream pipeline once per
  item, collecting successful results and errors separately.

  ## Delivery modes

  `DagBuilder` inspects the input schema of the first pipeline action and
  injects `__iterate_field__` and `__iterate_mode__` into the node's params:

  - `:item` — each item is delivered as `%{field => item}` (e.g. `%{contact: %{...}}`)
  - `:list` — each item is wrapped as `%{field => [item]}` (degenerate list delivery)

  ## Usage in a workflow

  In the workflow definition, `Iterate` is a node whose `"pipeline"` param lists
  the names of the downstream action nodes to run per item.  `DagBuilder`
  resolves those names to `{module, base_params}` pairs and injects them as
  `__iterate_pipeline__`.

  ## Failure strategies

  - `:skip_and_continue` (default) — failed items are recorded in `errors`,
    processing continues; always returns `:ok`
  - `:fail_workflow` — halts on the first item error and returns `{:error, reason}`
  - `:retry` — retries each failing item up to 3 total attempts before skipping

  ## Output

      %{
        results: [per-item pipeline outputs for successful items],
        errors:  [%{index: i, reason: reason} for failed items]
      }
  """

  use Jido.Action,
    name: "iterate",
    description: "Runs a downstream pipeline once per item in a list, collecting results.",
    schema: [
      items: [
        type: {:list, :any},
        required: true,
        doc: "List of items to process individually."
      ],
      strategy: [
        type: {:in, [:skip_and_continue, :fail_workflow, :retry]},
        required: false,
        default: :skip_and_continue,
        doc: "Failure strategy: :skip_and_continue (default), :fail_workflow, or :retry."
      ],
      __iterate_pipeline__: [
        type: {:list, :any},
        required: false,
        default: [],
        doc: "Injected by DagBuilder. List of {module, base_params} tuples."
      ],
      __iterate_field__: [
        type: :atom,
        required: false,
        doc: "Injected by DagBuilder. Key under which each item is delivered to the pipeline."
      ],
      __iterate_mode__: [
        type: {:in, [:list, :item]},
        required: false,
        default: :item,
        doc: "Injected by DagBuilder. :item delivers item as-is; :list wraps in [item]."
      ]
    ],
    output_schema: [
      results: [type: {:list, :any}, required: true, doc: "Successful per-item pipeline results."],
      errors: [type: {:list, :any}, required: true, doc: "Collected errors for failed items."]
    ]

  use Zaq.Engine.Workflows.Action

  alias Zaq.Agent.Tools.ItemOutcome
  alias Zaq.Agent.Tools.PipelineRunner
  alias Zaq.Engine.Workflows

  require Logger

  @impl Jido.Action
  def run(params, context) do
    items = Map.get(params, :items, [])
    strategy = Map.get(params, :strategy, :skip_and_continue)
    pipeline = Map.get(params, :__iterate_pipeline__, [])
    field = Map.get(params, :__iterate_field__)
    mode = Map.get(params, :__iterate_mode__, :item)

    Logger.info("[iterate] starting",
      run_id: Map.get(context, :run_id),
      step_name: Map.get(context, :step_name),
      total_items: length(items),
      strategy: strategy,
      delivery_mode: mode,
      field: field,
      pipeline_steps: length(pipeline)
    )

    result = execute_items(items, pipeline, field, mode, strategy, context)

    case result do
      {:ok, %{results: results, errors: errors, logs: logs}} ->
        Logger.info("[iterate] complete",
          run_id: Map.get(context, :run_id),
          step_name: Map.get(context, :step_name),
          total_items: length(items),
          successful: length(results),
          failed: length(errors)
        )

        {:ok, %{results: results, errors: errors}, logs: logs}

      {:error, reason} = err ->
        Logger.warning("[iterate] halted — fail_workflow strategy",
          run_id: Map.get(context, :run_id),
          step_name: Map.get(context, :step_name),
          reason: inspect(reason)
        )

        err
    end
  end

  defp execute_items(items, pipeline, field, mode, strategy, context) do
    total = length(items)
    run_id = Map.get(context, :run_id)
    step_name = Map.get(context, :step_name)

    result =
      items
      |> Enum.with_index()
      |> Enum.reduce_while({[], [], []}, fn {item, idx}, {results, errors, logs} ->
        t0 = log_start()
        delivery = build_delivery(item, field, mode)

        on_step = fn step_idx ->
          Workflows.broadcast_iterate_progress(run_id, step_name, %{
            current_item: idx + 1,
            total_items: total,
            current_step: step_idx
          })
        end

        outcome = PipelineRunner.invoke(delivery, pipeline, strategy, context, on_step)

        # Broadcast item completion (no current_step — item is done).
        Workflows.broadcast_iterate_progress(run_id, step_name, %{
          current_item: idx + 1,
          total_items: total
        })

        ItemOutcome.handle(outcome, strategy, idx, t0, results, errors, logs, %{
          log_entry: &log_entry/3,
          format_reason: &format_reason/1
        })
      end)

    PipelineRunner.finalize_result(result)
  end

  defp build_delivery(item, nil, _mode), do: item
  defp build_delivery(item, field, :item), do: %{field => item}
  defp build_delivery(item, field, :list), do: %{field => [item]}

  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
