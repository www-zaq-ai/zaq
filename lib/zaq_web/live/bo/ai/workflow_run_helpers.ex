defmodule ZaqWeb.Live.BO.AI.WorkflowRunHelpers do
  @moduledoc """
  Builders for BO-initiated workflow run events.

  Used by WorkflowsLive and WorkflowDetailLive when an admin triggers a run
  manually from the BO.
  """

  alias Zaq.Event

  @doc """
  Builds the `source_event` for a manual BO-triggered workflow run.

  Manual BO runs are admin runs: BO users carry no Person record, so step
  access comes from the explicit `skip_permissions` flag persisted on the
  run's source_event — the username on the actor is recorded purely for audit
  and grants nothing by itself.
  """
  @spec manual_source_event(struct() | nil, keyword()) :: Event.t()
  def manual_source_event(current_user, _opts \\ []) do
    event =
      Event.new(
        %{trigger_type: :manual},
        :engine,
        name: :workflow_run_manual,
        actor: %{
          id: nil,
          person_id: nil,
          name: current_user && current_user.username,
          provider: "bo"
        }
      )

    %{event | assigns: %{trigger_type: :manual, input: %{}, skip_permissions: true}}
  end
end
