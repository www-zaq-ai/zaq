defmodule Zaq.Engine.Workflows.Trigger.Behaviour do
  @moduledoc """
  Execution contract for all workflow trigger types.

  A trigger implementation is responsible for two things:

  1. `fire/2` — builds and returns a `%Zaq.Event{}` carrying the trigger type and
     input payload. It does NOT create a `WorkflowRun`. Run creation and workflow
     dispatch are the responsibility of `TriggerExecutor`, which calls `fire/2`
     once and then calls `Workflows.create_run/2` for each assigned workflow.

  2. `on_complete/2` — called by `WorkflowAgent` after a single run finishes.
     Dispatch outgoing events via `NodeRouter` here if needed.

  ## Implementing a trigger

      defmodule Zaq.Engine.Workflows.Triggers.MyTrigger do
        @behaviour Zaq.Engine.Workflows.Trigger.Behaviour

        @impl true
        def fire(trigger, input) do
          {:ok,
           %Zaq.Event{
             request: nil,
             next_hop: nil,
             trace_id: Ecto.UUID.generate(),
             assigns: %{trigger_type: :my_trigger, input: input}
           }}
        end

        @impl true
        def on_complete(run, _step_runs), do: :ok
      end
  """

  alias Zaq.Engine.Workflows.Step.Run, as: StepRun
  alias Zaq.Engine.Workflows.{Trigger, WorkflowRun}

  @doc """
  Builds a `%Zaq.Event{}` for the trigger firing. Returns `{:ok, event}`.
  Does NOT create a `WorkflowRun` — `TriggerExecutor` does that per workflow.
  """
  @callback fire(trigger :: Trigger.t(), input :: map()) ::
              {:ok, Zaq.Event.t()} | {:error, term()}

  @doc "Called by `WorkflowAgent` on run completion. Dispatch outgoing events here."
  @callback on_complete(run :: WorkflowRun.t(), step_runs :: [StepRun.t()]) ::
              :ok | {:error, term()}
end
