defmodule Zaq.Engine.Workflows.TriggerBehaviour do
  @moduledoc """
  Execution contract for all workflow trigger types.

  A trigger is responsible for two things:

  1. `fire/3` — builds a `%Zaq.Event{}`, creates a `WorkflowRun` row, and returns
     it. Starting the `WorkflowAgent` is the caller's responsibility — this keeps
     triggers stateless and independently testable.

  2. `on_complete/2` — called by `WorkflowAgent` after a run finishes. Dispatches
     an outgoing event via `NodeRouter` using `next_hop.destination` from the
     original `source_event`.

  ## Implementing a trigger

      defmodule Zaq.Engine.Workflows.Triggers.MyTrigger do
        @behaviour Zaq.Engine.Workflows.TriggerBehaviour

        @impl true
        def fire(trigger, workflow, input) do
          event = Zaq.Event.new(input, :agent,
            assigns: %{trigger_type: :my_trigger, input: input}
          )
          Zaq.Engine.Workflows.create_run(workflow, event)
        end

        @impl true
        def on_complete(run, _step_runs), do: :ok
      end
  """

  alias Zaq.Engine.Workflows.{StepRun, Trigger, Workflow, WorkflowRun}

  @doc """
  Builds a `%Zaq.Event{}` and inserts a `WorkflowRun` row.
  Returns `{:ok, run}` or `{:error, changeset}`.
  """
  @callback fire(trigger :: Trigger.t(), workflow :: Workflow.t(), input :: map()) ::
              {:ok, WorkflowRun.t()} | {:error, term()}

  @doc """
  Called by `WorkflowAgent` on run completion. Dispatch outgoing events here.
  """
  @callback on_complete(run :: WorkflowRun.t(), step_runs :: [StepRun.t()]) ::
              :ok | {:error, term()}
end
