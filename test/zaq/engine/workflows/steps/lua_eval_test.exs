defmodule Zaq.Engine.Workflows.Steps.LuaEvalTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  # These scenarios verify output persistence, not the Lua execution deadline.
  @eval_timeout_ms 10_000

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn
      %Zaq.Event{request: %{action: action}} = event
      when action in ["workflow.created", "run.started", "run.completed", "run.failed"] ->
        event

      %Zaq.Event{request: {:broadcast, "workflow:" <> _id, {notification, _run}}} = event
      when notification in [:run_created, :run_finished] ->
        event

      %Zaq.Event{request: {:broadcast, "workflow_run:" <> _id, {notification, _record}}} = event
      when notification in [:run_updated, :step_updated] ->
        event
    end)

    :ok
  end

  for {mode, expected} <- [{"first", 10}, {"list", [10, 20]}] do
    test "executes Lua return_mode #{mode} after a workflow JSON round trip" do
      attrs =
        %{
          name: "Lua JSON #{unquote(mode)} #{System.unique_integer([:positive])}",
          status: "active",
          nodes: [
            %{
              name: "lua",
              type: "action",
              module: "Zaq.Agent.Tools.Workflow.LuaEval",
              index: 0,
              params: %{
                code: "return 10, 20",
                return_mode: unquote(mode),
                eval_timeout_ms: @eval_timeout_ms
              }
            }
          ],
          edges: []
        }
        |> Jason.encode!()
        |> Jason.decode!()

      assert {:ok, workflow} = Workflows.create_workflow(attrs)

      assert {:ok, run} =
               Workflows.create_run(workflow, %{
                 "assigns" => %{},
                 "trace_id" => Ecto.UUID.generate()
               })

      assert {:ok, finished} = WorkflowRunAgent.execute(run)
      [step] = Workflows.list_step_runs(run.id)

      assert step.status == "completed", "Lua execution failed: #{inspect(step.errors)}"
      assert step.results["result"] == unquote(expected)
      assert finished.status == "completed"
    end
  end

  for {scenario, code, reason} <- [
        {"function output", "return function() return 42 end", "Jason.Encoder"},
        {"cyclic table output", "local t = {}; t.self = t; return t", "Jason.Encoder"},
        {"invalid UTF-8 output", "return string.char(255)", "invalid byte"},
        {"runtime error", "error('workflow lua failure')", "workflow lua failure"}
      ],
      mode <- ["first", "list"] do
    test "persists #{scenario} as a failed workflow with return_mode #{mode}" do
      assert {:ok, workflow} =
               Workflows.create_workflow(%{
                 name: "Lua failure #{System.unique_integer([:positive])}",
                 status: "active",
                 nodes: [
                   %{
                     name: "lua",
                     type: "action",
                     module: "Zaq.Agent.Tools.Workflow.LuaEval",
                     index: 0,
                     params: %{
                       code: unquote(code),
                       return_mode: unquote(mode),
                       eval_timeout_ms: @eval_timeout_ms
                     }
                   },
                   %{
                     name: "after",
                     type: "action",
                     module: "Zaq.Engine.Workflows.Test.CaptureValue",
                     index: 1,
                     params: %{}
                   }
                 ],
                 edges: [%{from: "lua", to: "after", mapping: %{"value" => "lua.result"}}]
               })

      assert {:ok, run} =
               Workflows.create_run(workflow, %{
                 "assigns" => %{},
                 "trace_id" => Ecto.UUID.generate()
               })

      assert {:ok, finished} = WorkflowRunAgent.execute(run)
      assert finished.status == "failed"
      assert Workflows.get_run!(run.id).status == "failed"
      assert finished.finished_at != nil

      # Only the failed Lua step is persisted; the downstream action never runs.
      assert [step] = Workflows.list_step_runs(run.id)
      assert step.step_name == "lua"
      assert step.status == "failed"
      assert step.finished_at != nil
      assert step.results == nil
      assert %{"reason" => reason} = step.errors
      assert reason =~ unquote(reason)
      assert [%{"event" => "step_failed"}] = step.logs
    end
  end
end
