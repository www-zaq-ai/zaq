defmodule Zaq.Engine.ActionSchedules.Worker do
  @moduledoc """
  Oban worker that executes a previously scheduled action.
  """

  use Oban.Worker, queue: :scheduled_actions, max_attempts: 3

  alias Zaq.Engine.ActionSchedules

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"schedule_id" => schedule_id, "action_key" => action_key, "params" => params}
      })
      when is_map(params) do
    with {:ok, module} <- ActionSchedules.resolve_action(action_key),
         {:ok, action_params} <- ActionSchedules.validate_action_params(module, params) do
      Jido.Exec.run(module, action_params, %{schedule_id: schedule_id, scheduled_action?: true})
    else
      {:error, {:unknown_action, _}} = error -> {:cancel, error}
      {:error, reason} -> {:error, reason}
    end
  end
end
