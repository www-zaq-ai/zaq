defmodule Zaq.Engine.Workflows.TriggerTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows.Trigger

  describe "changeset/2 — event_name required" do
    test "valid with event_name" do
      cs = Trigger.changeset(%Trigger{}, %{event_name: "manual_trigger"})
      assert cs.valid?
    end

    test "invalid without event_name" do
      cs = Trigger.changeset(%Trigger{}, %{})
      assert "can't be blank" in errors_on(cs).event_name
    end

    test "invalid with blank event_name" do
      cs = Trigger.changeset(%Trigger{}, %{event_name: ""})
      assert "can't be blank" in errors_on(cs).event_name
    end
  end

  describe "changeset/2 — enabled field" do
    test "defaults to true when not provided" do
      cs = Trigger.changeset(%Trigger{}, %{event_name: "manual_trigger"})
      assert Ecto.Changeset.get_field(cs, :enabled) == true
    end

    test "valid with enabled: true" do
      cs = Trigger.changeset(%Trigger{}, %{event_name: "manual_trigger", enabled: true})
      assert cs.valid?
    end

    test "valid with enabled: false" do
      cs = Trigger.changeset(%Trigger{}, %{event_name: "manual_trigger", enabled: false})
      assert cs.valid?
    end
  end
end
