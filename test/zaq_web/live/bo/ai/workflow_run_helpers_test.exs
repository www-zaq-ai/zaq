defmodule ZaqWeb.Live.BO.AI.WorkflowRunHelpersTest do
  use ExUnit.Case, async: true

  alias Zaq.Identity.ExecutionActor
  alias ZaqWeb.Live.BO.AI.WorkflowRunHelpers, as: Helpers

  describe "manual_source_event/1" do
    test "uses authenticated BO identity only when no Person is linked" do
      event = Helpers.manual_source_event(%{id: 7, username: "Admin"})
      assert {:ok, {:bo_user, "7"}} = ExecutionActor.identity(event.actor)
      refute Map.has_key?(event.actor, :person)

      event = Helpers.manual_source_event(%{id: 7, username: "Admin", person_id: 12})
      assert event.actor.person == %{id: 12, full_name: "Admin", team_ids: []}
      refute Map.has_key?(event.actor, :kind)
      assert {:ok, {:person, 12}} = ExecutionActor.identity(event.actor)
    end

    test "builds a manual admin event without actor identity when current user is nil" do
      event = Helpers.manual_source_event(nil)

      assert event.request == %{trigger_type: :manual}
      assert event.name == :workflow_run_manual
      assert event.next_hop.destination == :engine
      assert event.assigns == %{trigger_type: :manual, input: %{}, skip_permissions: true}

      assert event.actor == %{
               user_id: nil,
               person_id: nil,
               name: nil,
               provider: "bo",
               person: nil
             }
    end
  end
end
