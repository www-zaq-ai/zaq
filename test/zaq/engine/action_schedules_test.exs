defmodule Zaq.Engine.ActionSchedulesTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Engine.ActionSchedules
  alias Zaq.Engine.ActionSchedules.Worker

  defmodule MissingValidateParamsAction do
    def schema, do: []
  end

  defmodule PassthroughAction do
    def schema, do: []

    def validate_params(params), do: {:ok, params}
  end

  defmodule MixedEnumAction do
    def schema, do: [mode: [type: {:in, [:auto, "manual"]}]]

    def validate_params(params), do: {:ok, params}
  end

  defmodule EnumAction do
    def schema, do: [mode: [type: {:in, [:auto, :manual]}]]

    def validate_params(params), do: {:ok, params}
  end

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

    test "list_pending_schedules/0 returns all pending schedules ordered by scheduled_at" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, _late} =
                 ActionSchedules.schedule_action(%{
                   schedule_id: "list:late",
                   action_key: "basic.increment",
                   params: %{value: 1},
                   scheduled_at: future_datetime(7_200)
                 })

        assert {:ok, _early} =
                 ActionSchedules.schedule_action(%{
                   schedule_id: "list:early",
                   action_key: "basic.increment",
                   params: %{value: 1},
                   scheduled_at: future_datetime(3_600)
                 })

        assert {:ok, _middle} =
                 ActionSchedules.schedule_action(%{
                   schedule_id: "list:middle",
                   action_key: "basic.increment",
                   params: %{value: 1},
                   scheduled_at: future_datetime(5_400)
                 })

        assert ActionSchedules.list_pending_schedules()
               |> Enum.map(&arg(&1, :schedule_id)) == ["list:early", "list:middle", "list:late"]
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

    test "rejects blank schedule id and action key" do
      base = %{
        schedule_id: "schedule:1",
        action_key: "basic.increment",
        params: %{value: 1},
        scheduled_at: future_datetime()
      }

      assert {:error, {:invalid_field, :schedule_id, :blank}} =
               ActionSchedules.schedule_action(Map.put(base, :schedule_id, "   "))

      assert {:error, {:invalid_field, :action_key, :blank}} =
               ActionSchedules.schedule_action(%{base | action_key: "\n\t"})
    end

    test "rejects missing or non-string required string fields" do
      base = %{
        schedule_id: "schedule:1",
        action_key: "basic.increment",
        params: %{value: 1},
        scheduled_at: future_datetime()
      }

      assert {:error, {:invalid_field, :schedule_id, :required_string}} =
               ActionSchedules.schedule_action(Map.delete(base, :schedule_id))

      assert {:error, {:invalid_field, :action_key, :required_string}} =
               ActionSchedules.schedule_action(Map.put(base, :action_key, :basic_increment))
    end

    test "rejects params that are missing or not a map" do
      base = %{
        schedule_id: "schedule:1",
        action_key: "basic.increment",
        scheduled_at: future_datetime()
      }

      assert {:error, {:invalid_field, :params, :required_map}} =
               ActionSchedules.schedule_action(base)

      assert {:error, {:invalid_field, :params, :required_map}} =
               ActionSchedules.schedule_action(Map.put(base, :params, value: 1))
    end

    test "rejects scheduled_at that is missing or not a DateTime" do
      base = %{schedule_id: "schedule:1", action_key: "basic.increment", params: %{value: 1}}

      assert {:error, {:invalid_field, :scheduled_at, :required_utc_datetime}} =
               ActionSchedules.schedule_action(base)

      assert {:error, {:invalid_field, :scheduled_at, :required_utc_datetime}} =
               ActionSchedules.schedule_action(
                 Map.put(base, :scheduled_at, DateTime.to_iso8601(future_datetime()))
               )
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

  describe "resolve_action/1" do
    test "returns unknown_action for non-binary action keys" do
      assert {:error, {:unknown_action, :not_binary}} =
               ActionSchedules.resolve_action(:not_binary)

      assert {:error, {:unknown_action, 123}} = ActionSchedules.resolve_action(123)
    end
  end

  describe "validate_action_params/2" do
    test "wraps unloaded modules as invalid actions" do
      module = Zaq.Engine.ActionSchedulesTest.DoesNotExist

      assert {:error, {:invalid_action, ^module, _reason}} =
               ActionSchedules.validate_action_params(module, %{})
    end

    test "rejects loaded modules missing validate_params/1" do
      assert {:error, {:invalid_action, MissingValidateParamsAction, :missing_validate_params}} =
               ActionSchedules.validate_action_params(MissingValidateParamsAction, %{})
    end

    test "preserves params with non-atom and non-binary keys" do
      assert {:ok, %{1 => "one"}} =
               ActionSchedules.validate_action_params(PassthroughAction, %{1 => "one"})
    end

    test "leaves values unchanged for unknown atom keys without schema opts" do
      assert {:ok, %{extra: "value"}} =
               ActionSchedules.validate_action_params(PassthroughAction, %{extra: "value"})
    end

    test "does not coerce enum strings when matching allowed value is not an atom" do
      assert {:ok, %{mode: "manual"}} =
               ActionSchedules.validate_action_params(MixedEnumAction, %{"mode" => "manual"})
    end

    test "leaves non-binary enum values unchanged" do
      assert {:ok, %{mode: :auto}} =
               ActionSchedules.validate_action_params(EnumAction, %{mode: :auto})
    end
  end
end
