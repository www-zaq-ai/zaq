defmodule Zaq.Agent.Tools.Workflow.ScheduleActionTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Agent.Tools.Workflow.ScheduleAction
  alias Zaq.Engine.ActionSchedules

  test "schedules a registered action from UTC ISO8601 input" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      scheduled_at = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

      assert {:ok, %{schedule_id: "tool:schedule", job_id: job_id, scheduled_at: ^scheduled_at}} =
               ScheduleAction.run(
                 %{
                   schedule_id: "tool:schedule",
                   action_key: "basic.increment",
                   params: %{value: 1},
                   scheduled_at: scheduled_at
                 },
                 %{}
               )

      assert %Oban.Job{id: ^job_id} = ActionSchedules.get_pending_schedule("tool:schedule")
    end)
  end

  test "rejects non-UTC scheduled_at strings" do
    assert {:error, "scheduled_at must be UTC"} =
             ScheduleAction.run(
               %{
                 schedule_id: "tool:non-utc",
                 action_key: "basic.increment",
                 params: %{value: 1},
                 scheduled_at: "2026-07-15T12:00:00+02:00"
               },
               %{}
             )
  end

  test "rejects invalid scheduled_at strings before scheduling" do
    assert {:error, "scheduled_at must be a valid UTC ISO8601 datetime"} =
             ScheduleAction.run(
               %{
                 schedule_id: "tool:invalid-date",
                 action_key: "basic.increment",
                 params: %{value: 1},
                 scheduled_at: "not-a-datetime"
               },
               %{}
             )

    assert is_nil(ActionSchedules.get_pending_schedule("tool:invalid-date"))
  end

  test "rejects non-string scheduled_at values before scheduling" do
    assert {:error, "scheduled_at must be a UTC ISO8601 string"} =
             ScheduleAction.run(
               %{
                 schedule_id: "tool:non-string-date",
                 action_key: "basic.increment",
                 params: %{value: 1},
                 scheduled_at: nil
               },
               %{}
             )

    assert is_nil(ActionSchedules.get_pending_schedule("tool:non-string-date"))
  end

  test "surfaces target action validation errors" do
    scheduled_at = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

    assert {:error, _reason} =
             ScheduleAction.run(
               %{
                 schedule_id: "tool:bad-params",
                 action_key: "basic.increment",
                 params: %{},
                 scheduled_at: scheduled_at
               },
               %{}
             )
  end
end
