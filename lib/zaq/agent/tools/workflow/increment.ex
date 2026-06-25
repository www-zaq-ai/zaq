defmodule Zaq.Agent.Tools.Workflow.Increment do
  @moduledoc """
  Workflow-contract adapter around Jido's built-in increment action.

  The agent tool registry uses Jido's built-in increment action directly. Workflow
  DAG nodes additionally require the `Zaq.Engine.Workflows.Action` callbacks and a
  non-empty output schema, so this module keeps that contract shim and delegates
  execution to Jido's built-in action.

  ## Example

      iex> Zaq.Agent.Tools.Workflow.Increment.run(%{value: 2}, %{})
      {:ok, %{value: 3}}
  """

  alias Jido.Tools.Basic.Increment

  use Zaq.Engine.Workflows.Action,
    name: "increment",
    description: "Increment an integer value by 1.",
    schema: [
      value: [type: :integer, required: true, doc: "Value to increment"]
    ],
    output_schema: [
      value: [type: :integer, required: true, doc: "Incremented value"]
    ]

  @impl Jido.Action
  defdelegate run(params, context), to: Increment
end
