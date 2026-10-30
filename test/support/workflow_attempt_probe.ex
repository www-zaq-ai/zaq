defmodule Zaq.Engine.Workflows.Test.AttemptProbe do
  @moduledoc false
  use Jido.Action,
    name: "workflow_attempt_probe",
    schema: [input: [type: :any]],
    output_schema: [attempt: [type: :integer, required: true]]

  alias Jido.Action.Error

  @impl true
  def run(_params, context) do
    attempt = Agent.get_and_update(context.counter, &{&1 + 1, &1 + 1})

    case context.mode do
      :transient when attempt < 3 ->
        {:error, Error.execution_error("transient")}

      :deterministic ->
        {:error, Error.execution_error("rejected", %{retry: false})}

      :timeout ->
        send(context.owner, {:attempt_started, self(), attempt})

        receive do
          :release -> {:ok, %{attempt: attempt}}
        end

      _ ->
        {:ok, %{attempt: attempt}}
    end
  end
end
