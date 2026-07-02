defmodule Zaq.Engine.Workflows.Steps.BatchHangReproTest do
  @moduledoc """
  Reproduction harness for an unexplained hang reported on a client machine when
  running the batch/map test suite. `capture_log: true` (test_helper.exs) buffers
  Logger output per-test and only flushes it when the test *finishes* — so if a
  run genuinely hangs, none of the internal `Logger.error`/`Logger.info` calls in
  `StepRunner`/`WorkflowRunAgent` are ever visible. That is the "no log
  traceability" symptom on its own, independent of the hang's root cause.

  Every scenario below has ONE failing step in the body (`process`) and ONE
  failing step in `post_process`, matching the reported repro shape. Each test
  wraps `WorkflowRunAgent.execute/1` in a `Task` with a bounded `Task.yield/2` so
  a genuine hang fails the test with a clear message instead of blocking forever
  (`IO.puts` — not `Logger` — so progress is visible even mid-hang, since stdout
  is not captured).
  """

  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Step
  alias Zaq.Engine.Workflows.Workflow
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  @hang_timeout_ms 15_000

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp insert_map_workflow(name, map_params) do
    Zaq.Repo.insert!(%Workflow{
      name: "#{name} #{System.unique_integer([:positive])}",
      status: "active",
      nodes: [
        struct(Step.Node, %{
          name: "emit",
          type: "action",
          module: "Zaq.Engine.Workflows.Test.EmitItems",
          params: %{},
          index: 0
        }),
        struct(Step.Node, %{name: "m", type: "map", params: map_params, index: 1})
      ],
      edges: [struct(Step.Edge, %{from: "emit", to: "m"})]
    })
  end

  # Runs the workflow off the test process with a hard wall-clock deadline. On
  # genuine hang this returns `{:hung, task_pid}` instead of blocking the test
  # (and thus the whole suite / CI) forever.
  defp execute_with_deadline(wf) do
    {:ok, run} = Workflows.create_run(wf, @source_event)

    task =
      Task.async(fn ->
        IO.puts("[repro] starting WorkflowRunAgent.execute for run=#{run.id}")
        result = WorkflowRunAgent.execute(run)
        IO.puts("[repro] WorkflowRunAgent.execute RETURNED for run=#{run.id}")
        result
      end)

    case Task.yield(task, @hang_timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        IO.puts(
          "[repro] HANG DETECTED: run=#{run.id} did not return within #{@hang_timeout_ms}ms " <>
            "task_pid=#{inspect(task.pid)} " <>
            "current_stacktrace=#{inspect(Process.info(task.pid, :current_stacktrace))}"
        )

        {:hung, task.pid, run.id}
    end
  end

  describe "body raises + post_process raises (both are real exceptions, not {:error, _})" do
    test ":skip_and_continue — isolated fork strategy" do
      wf =
        insert_map_workflow("HangSkip", %{
          "over" => "items",
          "delivery" => "item",
          "strategy" => "skip_and_continue",
          "body" => [
            %{
              "name" => "raise_body",
              "type" => "action",
              "module" => "Zaq.Engine.Workflows.Test.RaiseOnEven",
              "params" => %{}
            }
          ],
          "post_process" => [
            %{
              "name" => "raise_post",
              "type" => "action",
              "module" => "Zaq.Engine.Workflows.Test.AlwaysRaise",
              "params" => %{}
            }
          ]
        })

      case execute_with_deadline(wf) do
        {:hung, _pid, run_id} ->
          flunk(
            "HUNG (skip_and_continue): run #{run_id} never returned within #{@hang_timeout_ms}ms"
          )

        {:ok, finished} ->
          IO.puts("[repro] skip_and_continue finished with status=#{finished.status}")

          rows = finished.id |> Workflows.list_step_runs()
          IO.puts("[repro] step_runs: " <> inspect(Enum.map(rows, &{&1.step_name, &1.status})))

        other ->
          flunk("unexpected result: #{inspect(other)}")
      end
    end

    test ":fail_workflow — non-isolated strategy" do
      wf =
        insert_map_workflow("HangFail", %{
          "over" => "items",
          "delivery" => "item",
          "strategy" => "fail_workflow",
          "body" => [
            %{
              "name" => "raise_body",
              "type" => "action",
              "module" => "Zaq.Engine.Workflows.Test.RaiseOnEven",
              "params" => %{}
            }
          ],
          "post_process" => [
            %{
              "name" => "raise_post",
              "type" => "action",
              "module" => "Zaq.Engine.Workflows.Test.AlwaysRaise",
              "params" => %{}
            }
          ]
        })

      case execute_with_deadline(wf) do
        {:hung, _pid, run_id} ->
          flunk("HUNG (fail_workflow): run #{run_id} never returned within #{@hang_timeout_ms}ms")

        {:ok, finished} ->
          IO.puts("[repro] fail_workflow finished with status=#{finished.status}")

          rows = finished.id |> Workflows.list_step_runs()
          IO.puts("[repro] step_runs: " <> inspect(Enum.map(rows, &{&1.step_name, &1.status})))

        other ->
          flunk("unexpected result: #{inspect(other)}")
      end
    end

    test ":retry — retry strategy on a permanently-raising body step" do
      wf =
        insert_map_workflow("HangRetry", %{
          "over" => "items",
          "delivery" => "item",
          "strategy" => "retry",
          "body" => [
            %{
              "name" => "raise_body",
              "type" => "action",
              "module" => "Zaq.Engine.Workflows.Test.RaiseOnEven",
              "params" => %{}
            }
          ],
          "post_process" => [
            %{
              "name" => "raise_post",
              "type" => "action",
              "module" => "Zaq.Engine.Workflows.Test.AlwaysRaise",
              "params" => %{}
            }
          ]
        })

      case execute_with_deadline(wf) do
        {:hung, _pid, run_id} ->
          flunk("HUNG (retry): run #{run_id} never returned within #{@hang_timeout_ms}ms")

        {:ok, finished} ->
          IO.puts("[repro] retry finished with status=#{finished.status}")

          rows = finished.id |> Workflows.list_step_runs()
          IO.puts("[repro] step_runs: " <> inspect(Enum.map(rows, &{&1.step_name, &1.status})))

        other ->
          flunk("unexpected result: #{inspect(other)}")
      end
    end
  end

  describe "body succeeds, only post_process raises" do
    test ":skip_and_continue — every fork's post_process raises" do
      wf =
        insert_map_workflow("HangPostOnly", %{
          "over" => "items",
          "delivery" => "item",
          "strategy" => "skip_and_continue",
          "body" => [
            %{
              "name" => "ok_body",
              "type" => "action",
              "module" => "Zaq.Engine.Workflows.Test.OkAction",
              "params" => %{}
            }
          ],
          "post_process" => [
            %{
              "name" => "raise_post",
              "type" => "action",
              "module" => "Zaq.Engine.Workflows.Test.AlwaysRaise",
              "params" => %{}
            }
          ]
        })

      case execute_with_deadline(wf) do
        {:hung, _pid, run_id} ->
          flunk("HUNG (post-only): run #{run_id} never returned within #{@hang_timeout_ms}ms")

        {:ok, finished} ->
          IO.puts("[repro] post-only finished with status=#{finished.status}")

          rows = finished.id |> Workflows.list_step_runs()
          IO.puts("[repro] step_runs: " <> inspect(Enum.map(rows, &{&1.step_name, &1.status})))

        other ->
          flunk("unexpected result: #{inspect(other)}")
      end
    end
  end
end
