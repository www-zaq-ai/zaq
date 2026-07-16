defmodule Zaq.Engine.ActionSchedulesTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Engine.ActionSchedules
  alias Zaq.Engine.ActionSchedules.Worker

  defp future_datetime(seconds \\ 3_600), do: DateTime.add(DateTime.utc_now(), seconds, :second)
  defp arg(job, key), do: job.args[Atom.to_string(key)] || job.args[key]

  describe "schedule_action/2" do
    test "creates a pending Oban job for a new schedule id" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, job} =
                 ActionSchedules.schedule_action(%{
                   schedule_id: "reminder:1",
                   action_key: "basic.increment",
                   params: %{value: 1},
                   scheduled_at: future_datetime()
                 })

        assert job.worker == inspect(Worker)
        assert job.queue == "scheduled_actions"
        assert arg(job, :schedule_id) == "reminder:1"
        assert arg(job, :action_key) == "basic.increment"
        assert arg(job, :params) in [%{"value" => 1}, %{value: 1}]

        assert %Oban.Job{id: id} = ActionSchedules.get_pending_schedule("reminder:1")
        assert id == job.id
      end)
    end

    test "updates an existing pending schedule by schedule id" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        first_time = future_datetime(3_600)
        second_time = future_datetime(7_200)

        assert {:ok, first} =
                 ActionSchedules.schedule_action(%{
                   schedule_id: "buffer:user-1",
                   action_key: "basic.increment",
                   params: %{value: 1},
                   scheduled_at: first_time
                 })

        assert {:ok, second} =
                 ActionSchedules.schedule_action(%{
                   schedule_id: "buffer:user-1",
                   action_key: "basic.decrement",
                   params: %{value: 5},
                   scheduled_at: second_time
                 })

        assert second.id == first.id
        assert arg(second, :action_key) == "basic.decrement"
        assert arg(second, :params) in [%{"value" => 5}, %{value: 5}]
        assert DateTime.compare(second.scheduled_at, first.scheduled_at) == :gt

        assert [job] = ActionSchedules.list_pending_schedules(["buffer:user-1"])
        assert job.id == first.id
      end)
    end

    test "rejects unknown actions before enqueueing" do
      assert {:error, {:unknown_action, "nope.missing"}} =
               ActionSchedules.schedule_action(%{
                 schedule_id: "bad:action",
                 action_key: "nope.missing",
                 params: %{},
                 scheduled_at: future_datetime()
               })
    end

    test "rejects params that do not satisfy the target action schema" do
      assert {:error, _reason} =
               ActionSchedules.schedule_action(%{
                 schedule_id: "bad:params",
                 action_key: "basic.increment",
                 params: %{},
                 scheduled_at: future_datetime()
               })
    end

    test "stores validated params including target action defaults" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, job} =
                 ActionSchedules.schedule_action(%{
                   schedule_id: "log:default-level",
                   action_key: "basic.log",
                   params: %{message: "Hi in schedule"},
                   scheduled_at: future_datetime()
                 })

        assert arg(job, :params) in [
                 %{"message" => "Hi in schedule", "level" => :info},
                 %{message: "Hi in schedule", level: :info}
               ]
      end)
    end

    test "rehydrates JSONB string enum values before target validation" do
      assert {:ok, %{message: "Hi in schedule", level: :info}} =
               ActionSchedules.validate_action_params(Jido.Tools.Basic.Log, %{
                 "message" => "Hi in schedule",
                 "level" => "info"
               })
    end

    test "rejects non-UTC and past datetimes" do
      non_utc = %{future_datetime() | time_zone: "Europe/Paris", utc_offset: 3_600}
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      base = %{schedule_id: "bad:time", action_key: "basic.increment", params: %{value: 1}}

      assert {:error, {:invalid_field, :scheduled_at, :must_be_utc}} =
               ActionSchedules.schedule_action(Map.put(base, :scheduled_at, non_utc))

      assert {:error, {:invalid_field, :scheduled_at, :must_be_future}} =
               ActionSchedules.schedule_action(Map.put(base, :scheduled_at, past))
    end
  end
end
