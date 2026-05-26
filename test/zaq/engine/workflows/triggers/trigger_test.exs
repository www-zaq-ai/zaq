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

  describe "changeset/2 — trigger_type field" do
    test "defaults to 'event' when not provided" do
      cs = Trigger.changeset(%Trigger{}, %{event_name: "manual_trigger"})
      assert Ecto.Changeset.get_field(cs, :trigger_type) == "event"
    end

    test "valid with trigger_type: 'event'" do
      cs = Trigger.changeset(%Trigger{}, %{event_name: "manual_trigger", trigger_type: "event"})
      assert cs.valid?
    end

    test "invalid with unknown trigger_type" do
      cs = Trigger.changeset(%Trigger{}, %{event_name: "manual_trigger", trigger_type: "http"})
      assert "is invalid" in errors_on(cs).trigger_type
    end
  end

  describe "changeset/2 — cron trigger" do
    test "valid with trigger_type cron and valid schedule" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          event_name: "cron.hourly",
          trigger_type: "cron",
          cron_schedule: "0 * * * *"
        })

      assert cs.valid?
    end

    test "invalid when trigger_type is cron but cron_schedule is missing" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          event_name: "cron.hourly",
          trigger_type: "cron"
        })

      assert "is required for cron triggers" in errors_on(cs).cron_schedule
    end

    test "invalid when trigger_type is cron but cron_schedule is blank" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          event_name: "cron.hourly",
          trigger_type: "cron",
          cron_schedule: ""
        })

      assert "is required for cron triggers" in errors_on(cs).cron_schedule
    end

    test "invalid when cron_schedule has wrong number of fields" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          event_name: "cron.daily",
          trigger_type: "cron",
          cron_schedule: "0 * * *"
        })

      assert "must be a valid 5-field cron expression" in errors_on(cs).cron_schedule
    end

    test "valid with step expression" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          event_name: "cron.every5",
          trigger_type: "cron",
          cron_schedule: "*/5 * * * *"
        })

      assert cs.valid?
    end

    test "valid with day-of-week schedule" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          event_name: "cron.weekly",
          trigger_type: "cron",
          cron_schedule: "0 0 * * 1"
        })

      assert cs.valid?
    end
  end

  describe "changeset/2 — event trigger with cron_schedule set" do
    test "invalid when trigger_type is event but cron_schedule is provided" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          event_name: "order.created",
          trigger_type: "event",
          cron_schedule: "0 * * * *"
        })

      assert "must be blank for event triggers" in errors_on(cs).cron_schedule
    end

    test "valid when trigger_type is event and cron_schedule is nil" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          event_name: "order.created",
          trigger_type: "event",
          cron_schedule: nil
        })

      assert cs.valid?
    end
  end
end
