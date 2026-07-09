defmodule Zaq.Agent.Tools.Workflow.Sleep do
  @moduledoc """
  Workflow-contract adapter around Jido's built-in sleep action.

  The agent tool registry uses Jido's built-in sleep action directly. Workflow DAG
  nodes additionally require the `Zaq.Engine.Workflows.Action` callbacks and a
  non-empty output schema, so this module keeps only that contract shim and
  delegates execution to Jido's built-in action.

  ## Example

      iex> Zaq.Agent.Tools.Workflow.Sleep.run(%{duration_ms: 500}, %{})
      {:ok, %{duration_ms: 500}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "sleep",
    description: "Pause workflow execution for a duration in milliseconds.",
    schema: [
      duration_ms: [
        type: :non_neg_integer,
        required: true,
        doc: "Duration to sleep in milliseconds"
      ]
    ],
    output_schema: [
      duration_ms: [type: :non_neg_integer, required: true, doc: "Duration slept"]
    ]

  @impl Jido.Action
  defdelegate run(params, context), to: Jido.Tools.Basic.Sleep
end
