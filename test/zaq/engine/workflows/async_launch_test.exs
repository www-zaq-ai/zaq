defmodule Zaq.Engine.Workflows.AsyncLaunchTest do
  # async: false → DataCase runs the sandbox in shared mode, so the supervised
  # background task spawned by start_run_async/2 can use the DB connection.
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Engine.Workflows.Test.InboxWithResults",
    params: %{},
    index: 0
  }

  defp create_workflow do
    {:ok, w} =
      Workflows.create_workflow(%{name: "W", status: "draft", nodes: [@valid_node], edges: []})

    w
  end

  defp create_run(workflow) do
    source_event = %Zaq.Event{
      request: nil,
      next_hop: nil,
      trace_id: Ecto.UUID.generate(),
      assigns: %{trigger_type: :manual, input: %{}}
    }

    {:ok, run} = Workflows.create_run(workflow, source_event)
    run
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  describe "start_run_async/2" do
    test "returns :ok and drives the run off-caller to a terminal state" do
      run = create_workflow() |> create_run()

      assert :ok = Workflows.start_run_async(run)

      assert eventually(fn -> Workflows.get_run!(run.id).status != "pending" end),
             "expected the supervised task to move the run out of \"pending\""
    end
  end

  describe "resume_run_async/2" do
    test "returns :ok (launch succeeded) even when the run itself is not resumable" do
      run = create_workflow() |> create_run()
      {:ok, run} = Workflows.update_run(run, %{status: "completed"})

      # resume_run/2 rejects a terminal run internally; the async wrapper still
      # returns :ok because the *launch* succeeded — it must never raise a
      # MatchError in the calling process on the start_child result.
      assert :ok = Workflows.resume_run_async(run)
    end
  end
end
