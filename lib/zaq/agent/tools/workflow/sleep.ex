defmodule Zaq.Agent.Tools.Workflow.Sleep do
  @moduledoc """
  Workflow action: pauses execution for a given duration.

  ## Example

      iex> Zaq.Agent.Tools.Workflow.Sleep.run(%{duration_ms: 500}, %{})
      {:ok, %{slept_ms: 500}}
  """

  use Jido.Action,
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
      slept_ms: [type: :non_neg_integer, required: true, doc: "Actual duration slept"]
    ]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(%{duration_ms: ms}, _ctx) do
    Process.sleep(ms)
    {:ok, %{slept_ms: ms}}
  end
end
