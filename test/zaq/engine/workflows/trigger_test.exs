defmodule Zaq.Engine.Workflows.TriggerTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows.Trigger

  describe "changeset/2 — required fields" do
    test "valid with type only" do
      cs = Trigger.changeset(%Trigger{}, %{type: "manual"})
      assert cs.valid?
    end

    test "invalid without type" do
      cs = Trigger.changeset(%Trigger{}, %{})
      assert "can't be blank" in errors_on(cs).type
    end

    test "invalid with unknown type" do
      cs = Trigger.changeset(%Trigger{}, %{type: "smoke_signal"})
      assert "is invalid" in errors_on(cs).type
    end
  end

  describe "changeset/2 — execution_mode" do
    test "defaults to parallel when not provided" do
      cs = Trigger.changeset(%Trigger{}, %{type: "manual"})
      assert Ecto.Changeset.get_field(cs, :execution_mode) == :parallel
    end

    test "accepts serial" do
      cs = Trigger.changeset(%Trigger{}, %{type: "manual", execution_mode: "serial"})
      assert cs.valid?
    end

    test "accepts parallel" do
      cs = Trigger.changeset(%Trigger{}, %{type: "manual", execution_mode: "parallel"})
      assert cs.valid?
    end

    test "rejects unknown execution_mode" do
      cs = Trigger.changeset(%Trigger{}, %{type: "manual", execution_mode: "queue"})
      assert "is invalid" in errors_on(cs).execution_mode
    end
  end

  describe "changeset/2 — max_concurrency" do
    test "nil is valid for parallel (unlimited)" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          type: "manual",
          execution_mode: "parallel",
          max_concurrency: nil
        })

      assert cs.valid?
    end

    test "positive integer is valid" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          type: "manual",
          execution_mode: "parallel",
          max_concurrency: 3
        })

      assert cs.valid?
    end

    test "zero is invalid" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          type: "manual",
          execution_mode: "parallel",
          max_concurrency: 0
        })

      assert "must be greater than 0" in errors_on(cs).max_concurrency
    end

    test "negative is invalid" do
      cs =
        Trigger.changeset(%Trigger{}, %{
          type: "manual",
          execution_mode: "parallel",
          max_concurrency: -1
        })

      assert "must be greater than 0" in errors_on(cs).max_concurrency
    end
  end

  describe "changeset/2 — on_failure" do
    test "defaults to continue when not provided" do
      cs = Trigger.changeset(%Trigger{}, %{type: "manual"})
      assert Ecto.Changeset.get_field(cs, :on_failure) == :continue
    end

    test "accepts stop" do
      cs = Trigger.changeset(%Trigger{}, %{type: "manual", on_failure: "stop"})
      assert cs.valid?
    end

    test "accepts continue" do
      cs = Trigger.changeset(%Trigger{}, %{type: "manual", on_failure: "continue"})
      assert cs.valid?
    end

    test "rejects unknown on_failure value" do
      cs = Trigger.changeset(%Trigger{}, %{type: "manual", on_failure: "retry"})
      assert "is invalid" in errors_on(cs).on_failure
    end
  end

  describe "changeset/2 — type-specific config validation" do
    test "scheduler requires cron key in config" do
      cs = Trigger.changeset(%Trigger{}, %{type: "scheduler", config: %{}})
      assert "missing required key 'cron' for scheduler trigger" in errors_on(cs).config
    end

    test "scheduler is valid with cron key" do
      cs = Trigger.changeset(%Trigger{}, %{type: "scheduler", config: %{"cron" => "0 * * * *"}})
      assert cs.valid?
    end

    test "signal requires topic key in config" do
      cs = Trigger.changeset(%Trigger{}, %{type: "signal", config: %{}})
      assert "missing required key 'topic' for signal trigger" in errors_on(cs).config
    end

    test "signal is valid with topic key" do
      cs =
        Trigger.changeset(%Trigger{}, %{type: "signal", config: %{"topic" => "email.received"}})

      assert cs.valid?
    end

    test "manual does not require config keys" do
      cs = Trigger.changeset(%Trigger{}, %{type: "manual", config: %{}})
      assert cs.valid?
    end

    test "webhook does not require config keys" do
      cs = Trigger.changeset(%Trigger{}, %{type: "webhook", config: %{}})
      assert cs.valid?
    end
  end

  describe "Trigger.module/1" do
    test "maps all known types to modules" do
      alias Zaq.Engine.Workflows.Triggers.{Manual, Scheduler, Signal, Webhook}

      assert {:ok, Manual} = Trigger.module(%Trigger{type: "manual"})
      assert {:ok, Webhook} = Trigger.module(%Trigger{type: "webhook"})
      assert {:ok, Scheduler} = Trigger.module(%Trigger{type: "scheduler"})
      assert {:ok, Signal} = Trigger.module(%Trigger{type: "signal"})
    end

    test "returns error for unknown type" do
      assert {:error, :unknown_type} = Trigger.module(%Trigger{type: "unknown"})
    end
  end
end
