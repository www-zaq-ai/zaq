defmodule Zaq.Engine.Workflows.Trigger.Type.Manual do
  @moduledoc """
  Trigger fired explicitly by a user via the BO UI or API.

  `fire/2` builds the event for use by `TriggerExecutor`.
  `fire_for_workflow/2` is the implicit manual path — fires against a single
  workflow with no trigger record required (used by `Workflows.run_workflow_manually/3`).
  """

  @behaviour Zaq.Engine.Workflows.Trigger.Behaviour

  alias Zaq.{Engine.Workflows, Event}

  @impl true
  def fire(_trigger, input) do
    {:ok,
     %Event{
       request: nil,
       next_hop: nil,
       trace_id: Ecto.UUID.generate(),
       assigns: %{trigger_type: :manual, input: input}
     }}
  end

  @doc "Fires against a single workflow without a trigger record."
  @spec fire_for_workflow(Workflows.Workflow.t(), map()) ::
          {:ok, Workflows.WorkflowRun.t()} | {:error, term()}
  def fire_for_workflow(workflow, input) do
    event = %Event{
      request: nil,
      next_hop: nil,
      trace_id: Ecto.UUID.generate(),
      assigns: %{trigger_type: :manual, input: input}
    }

    Workflows.create_run(workflow, event)
  end

  @impl true
  def on_complete(_run, _step_runs), do: :ok
end
