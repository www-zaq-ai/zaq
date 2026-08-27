defmodule ZaqWeb.Live.BO.AI.WorkflowRunHelpers do
  @moduledoc """
  Builders for BO-initiated workflow run events.

  Used by WorkflowsLive and WorkflowDetailLive when an admin triggers a run
  manually from the BO.
  """

  alias Zaq.Event

  @doc """
  Builds the `source_event` for a manual BO-triggered workflow run.

  Manual BO runs are admin runs: step access comes from the explicit
  `skip_permissions` flag persisted on the run's source_event. Any attached
  person identity is retained on the actor for audit only; it is not the source
  of the bypass.
  """
  @spec manual_source_event(struct() | nil, keyword()) :: Event.t()
  def manual_source_event(current_user, _opts \\ []) do
    event =
      Event.new(
        %{trigger_type: :manual},
        :engine,
        name: :workflow_run_manual,
        actor: %{
          user_id: user_attr(current_user, :id),
          person_id: user_attr(current_user, :person_id),
          name: user_attr(current_user, :username),
          provider: "bo",
          person: current_user_person(current_user)
        }
      )

    %{event | assigns: %{trigger_type: :manual, input: %{}, skip_permissions: true}}
  end

  defp current_user_person(current_user) do
    case user_attr(current_user, :person_id) do
      nil ->
        nil

      id ->
        %{
          id: id,
          full_name: user_attr(current_user, :username),
          team_ids: user_attr(current_user, :team_ids) || []
        }
    end
  end

  defp user_attr(user, key) when is_map(user),
    do: Map.get(user, key) || Map.get(user, Atom.to_string(key))

  defp user_attr(_user, _key), do: nil
end
