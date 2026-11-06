defmodule Zaq.Engine.Workflows.Test.ExecutionProbe do
  @moduledoc false
  use Jido.Action,
    name: "workflow_execution_probe",
    schema: [input: [type: :any]],
    output_schema: [value: [type: :string]]

  use Zaq.Engine.Workflows.Action

  @impl true
  def run(params, %{outer: true} = context) do
    Jido.Exec.run(__MODULE__, params, Map.delete(context, :outer),
      timeout: 0,
      max_retries: 0,
      backoff: 0,
      telemetry: :silent
    )
  end

  def run(_params, %{raise: exception}), do: raise(exception)
  def run(_params, %{outcome: outcome}), do: outcome
end
