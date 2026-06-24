defmodule Zaq.Agent.Tools.Workflow.Increment do
  @moduledoc """
  Workflow-contract adapter around Jido's built-in increment action.

  The agent tool registry uses Jido's built-in increment action directly. Workflow
  DAG nodes additionally require the `Zaq.Engine.Workflows.Action` callbacks and a
  non-empty output schema, so this module keeps that contract shim and delegates
  execution to Jido's built-in action.

  Unlike the chat-tool path, the workflow `StepRunner` invokes `run/2` directly
  and does **not** run Jido's NimbleOptions validation/coercion. Values mapped in
  from upstream nodes therefore arrive with their original runtime type — a sheet
  cell such as `sequence` reaches us as the **string** `"2"`, not an integer.
  Jido's `value + 1` would then raise `bad argument in arithmetic expression`, so
  we coerce `value` to an integer here before delegating.

  ## Example

      iex> Zaq.Agent.Tools.Workflow.Increment.run(%{value: 2}, %{})
      {:ok, %{value: 3}}

      iex> Zaq.Agent.Tools.Workflow.Increment.run(%{value: "2"}, %{})
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
  def run(params, context) do
    raw = Map.get(params, :value, Map.get(params, "value"))

    case coerce_integer(raw) do
      {:ok, int} ->
        params
        |> Map.put(:value, int)
        |> Increment.run(context)

      :error ->
        {:error, "increment requires an integer value, got: #{inspect(raw)}"}
    end
  end

  defp coerce_integer(value) when is_integer(value), do: {:ok, value}

  defp coerce_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp coerce_integer(_value), do: :error
end
