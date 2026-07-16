defmodule Zaq.Engine.ActionSchedules.WorkerTest do
  use Zaq.DataCase, async: true
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Engine.ActionSchedules.Worker

  test "executes the registered action through Jido.Exec" do
    assert {:ok, %{value: 2}} =
             perform_job(Worker, %{
               schedule_id: "run:increment",
               action_key: "basic.increment",
               params: %{"value" => 1}
             })
  end

  test "executes JSONB-round-tripped enum defaults for basic.log" do
    assert {:ok, %{level: :info, message: "Hi in schedule"}} =
             perform_job(Worker, %{
               schedule_id: "run:log",
               action_key: "basic.log",
               params: %{"message" => "Hi in schedule", "level" => "info"}
             })
  end

  test "cancels jobs for actions that are no longer registered" do
    assert {:cancel, {:error, {:unknown_action, "missing.action"}}} =
             perform_job(Worker, %{
               schedule_id: "run:missing",
               action_key: "missing.action",
               params: %{}
             })
  end

  test "returns validation errors for registered actions with invalid params" do
    assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
             perform_job(Worker, %{
               schedule_id: "run:invalid-increment",
               action_key: "basic.increment",
               params: %{}
             })

    assert error.message =~ "Invalid parameters for Action"
    assert error.message =~ "required :value option not found"
  end
end
