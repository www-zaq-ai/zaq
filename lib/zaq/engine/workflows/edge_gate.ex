defmodule Zaq.Engine.Workflows.EdgeGate do
  @moduledoc """
  Connects native Runic edge predicates to ZAQ's durable edge traces.

  A false predicate records a skipped edge without failing a Runic runnable.
  Passing predicates forward the original fact to the mapping action, which
  records completion only after mapping succeeds. Runtime identifiers belong
  in hooks, outside the predicate's portable identity.
  """

  alias Runic.Workflow
  alias Zaq.Engine.Workflows.EdgeGate
  alias Zaq.Engine.Workflows.Steps.EdgeStep

  require Runic

  @doc "Adds a conditional gate before an edge's mapping action."
  @spec add(
          Workflow.t(),
          map(),
          atom(),
          String.t(),
          String.t() | nil,
          non_neg_integer(),
          keyword()
        ) ::
          Workflow.t()
  def add(workflow, condition, name, edge_name, run_id, source_index, opts) do
    predicate =
      Runic.condition(
        fn fact ->
          EdgeStep.condition_matches?(
            ^condition,
            EdgeGate.condition_input(fact)
          )
        end,
        name: ^name
      )

    before_hook = fn event, _context ->
      validate_predicate(
        condition,
        condition_input(event.input_fact.value),
        edge_name,
        run_id,
        source_index
      )
    end

    after_hook = fn event, _context ->
      if event.result == false do
        EdgeStep.skip_condition(
          condition,
          condition_input(event.input_fact.value),
          edge_name,
          run_id,
          source_index
        )
      end

      :ok
    end

    workflow
    |> Workflow.add(predicate, opts)
    |> Workflow.add_before_hooks([{name, [before_hook]}])
    |> Workflow.add_after_hooks([{name, [after_hook]}])
  end

  # Public so Runic's compiled predicate can call it. Match ActionNode's params
  # convention for evaluation only; the gate still forwards the original fact.
  @doc false
  def condition_input(value) when is_map(value), do: value
  def condition_input(value), do: %{input: value}

  # Runic treats some predicate exceptions as non-matches. Preflight through the
  # same evaluator makes genuine ZAQ faults failed runnables with durable traces,
  # instead of silently turning them into false conditions or escaping the driver.
  defp validate_predicate(condition, fact, edge_name, run_id, source_index) do
    EdgeStep.condition_matches?(condition, fact)
    :ok
  rescue
    exception ->
      EdgeStep.fail_condition(run_id, edge_name, source_index, exception)
      {:error, exception}
  end
end
