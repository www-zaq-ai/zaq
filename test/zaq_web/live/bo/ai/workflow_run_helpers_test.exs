defmodule ZaqWeb.Live.BO.AI.WorkflowRunHelpersTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.AI.WorkflowRunHelpers, as: Helpers

  describe "manual_source_event/1" do
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
