defmodule Zaq.Engine.ActionSchedules.Worker do
  @moduledoc """
  Oban worker that executes a previously scheduled action.

  Scheduled actions execute through `Zaq.Agent.Tools.ActionContract.execute/4`, which
  normalizes persisted JSON params and runs `Jido.Exec`, because this worker and the
  scheduled actions context both live inside the engine node. This path does not
  need a `NodeRouter` hop while the Oban worker is engine-local. If the worker is
  moved to another node, this execution path must be refactored to dispatch a
  `%Zaq.Event{}` through `NodeRouter.dispatch/1`.
  """

  use Oban.Worker, queue: :scheduled_actions, max_attempts: 3

  alias Zaq.Agent.Tools.ActionContract
  alias Zaq.Engine.ActionSchedules

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"schedule_id" => schedule_id, "action_key" => action_key, "params" => params}
      })
      when is_map(params) do
    case ActionSchedules.resolve_action(action_key) do
      {:ok, module} ->
        ActionContract.execute(module, params, %{
          schedule_id: schedule_id,
          scheduled_action?: true
        })

      {:error, {:unknown_action, _}} = error ->
        {:cancel, error}
    end
  end

  def perform(%Oban.Job{args: %{"schedule_id" => schedule_id}}) do
    {:cancel, {:error, {:invalid_params, schedule_id}}}
  end
end
