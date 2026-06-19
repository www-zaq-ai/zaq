defmodule Zaq.Engine.Workflows.Steps.MapNodeTest do
  @moduledoc """
  End-to-end tests for the general `map` iteration primitive: a `map` node fans an
  inline `body` pipeline over the `over` collection of its upstream fact (Runic
  FanOut → body → FanIn/reduce), writing per-fork StepRuns + one aggregate row.
  """
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.DagBuilder
  alias Zaq.Engine.Workflows.WorkflowRun

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp map_workflow do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Map #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{
            name: "emit",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.EmitItems",
            params: %{},
            index: 0
          },
          %{
            name: "m",
            type: "map",
            params: %{
              "over" => "items",
              "body" => [
                %{
                  "name" => "ok",
                  "type" => "action",
                  "module" => "Zaq.Engine.Workflows.Test.OkAction",
                  "params" => %{}
                }
              ]
            },
            index: 1
          }
        ],
        edges: [%{from: "emit", to: "m"}]
      })

    wf
  end

  test "runs the body once per item and collects results" do
    assert {:ok, %WorkflowRun{} = finished} =
             Workflows.create_and_start_run(map_workflow(), @source_event)

    assert finished.status == "completed"

    names = finished.id |> Workflows.list_step_runs() |> Enum.map(& &1.step_name)

    # the source step, one per-fork body row per item, and the aggregate row
    assert "emit" in names
    assert "m/ok[0]" in names
    assert "m/ok[1]" in names
    assert "m/ok[2]" in names
    assert "m" in names
  end

  test "aggregate StepRun carries the per-item summary" do
    {:ok, finished} = Workflows.create_and_start_run(map_workflow(), @source_event)

    aggregate = finished.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "m"))

    assert aggregate.status == "completed"
    assert aggregate.results["count"] == 3
    assert length(aggregate.results["results"]) == 3
  end

  test "all per-fork body rows complete" do
    {:ok, finished} = Workflows.create_and_start_run(map_workflow(), @source_event)

    fork_rows =
      finished.id
      |> Workflows.list_step_runs()
      |> Enum.filter(&String.starts_with?(&1.step_name, "m/ok["))

    assert length(fork_rows) == 3
    assert Enum.all?(fork_rows, &(&1.status == "completed"))
  end

  # --- strategies (resume item #1) -----------------------------------------
  #
  # Source emits [%{n: 1}, %{n: 2}, %{n: 3}] (indices 0,1,2). `FailEvenN` fails on
  # the even item (n=2, index 1) and succeeds on the odds.

  defp strategy_workflow(strategy, body_module \\ "Zaq.Engine.Workflows.Test.FailEvenN") do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "MapStrategy #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{
            name: "emit",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.EmitItems",
            params: %{},
            index: 0
          },
          %{
            name: "m",
            type: "map",
            params: %{
              "over" => "items",
              "strategy" => strategy,
              "body" => [
                %{"name" => "fail", "type" => "action", "module" => body_module, "params" => %{}}
              ]
            },
            index: 1
          }
        ],
        edges: [%{from: "emit", to: "m"}]
      })

    wf
  end

  test ":skip_and_continue — run completes, failing item isolated as non-fatal + collected" do
    {:ok, finished} =
      Workflows.create_and_start_run(strategy_workflow("skip_and_continue"), @source_event)

    assert finished.status == "completed"

    rows = Workflows.list_step_runs(finished.id)
    failed_fork = Enum.find(rows, &(&1.step_name == "m/fail[1]"))

    # isolated failure: recorded as `failed_fatal` so it stays out of the run-fail check
    assert failed_fork.status == "failed_fatal"

    odd_forks = Enum.filter(rows, &(&1.step_name in ["m/fail[0]", "m/fail[2]"]))
    assert Enum.all?(odd_forks, &(&1.status == "completed"))

    aggregate = Enum.find(rows, &(&1.step_name == "m"))
    assert aggregate.status == "completed"
    assert length(aggregate.results["results"]) == 2

    assert [%{"index" => 1, "reason" => reason}] = aggregate.results["errors"]
    assert reason =~ "even_n:2"
    assert aggregate.results["count"] == 3
  end

  test ":fail_workflow — a failing item fails the whole run (fatal fork row)" do
    {:ok, finished} =
      Workflows.create_and_start_run(strategy_workflow("fail_workflow"), @source_event)

    assert finished.status == "failed"

    failed_fork =
      finished.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "m/fail[1]"))

    # non-isolated failure: plain `failed`, which fails the run
    assert failed_fork.status == "failed"
  end

  test "multi-step body — a failure short-circuits the rest of that fork only" do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "MapMultiStep #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{
            name: "emit",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.EmitItems",
            params: %{},
            index: 0
          },
          %{
            name: "m",
            type: "map",
            params: %{
              "over" => "items",
              "strategy" => "skip_and_continue",
              "body" => [
                %{
                  "name" => "fail",
                  "type" => "action",
                  "module" => "Zaq.Engine.Workflows.Test.FailEvenN",
                  "params" => %{}
                },
                %{
                  "name" => "after",
                  "type" => "action",
                  "module" => "Zaq.Engine.Workflows.Test.MarkDone",
                  "params" => %{}
                }
              ]
            },
            index: 1
          }
        ],
        edges: [%{from: "emit", to: "m"}]
      })

    {:ok, finished} = Workflows.create_and_start_run(wf, @source_event)
    assert finished.status == "completed"

    names = finished.id |> Workflows.list_step_runs() |> Enum.map(& &1.step_name)

    # n=2 (index 1) fails the first body step; the second step is short-circuited,
    # so only ONE row exists for that fork and it is the failed one.
    assert "m/fail[1]" in names
    refute "m/after[1]" in names

    # the odd items (index 0, 2) run both body steps to completion
    assert "m/after[0]" in names
    assert "m/after[2]" in names

    aggregate = finished.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "m"))
    assert [%{"index" => 1}] = aggregate.results["errors"]
    assert length(aggregate.results["results"]) == 2
  end

  test ":retry — a flaky fork is re-run until it succeeds, run completes" do
    {:ok, finished} =
      Workflows.create_and_start_run(
        strategy_workflow("retry", "Zaq.Engine.Workflows.Test.FlakyTwice"),
        @source_event
      )

    assert finished.status == "completed"

    fork_rows =
      finished.id
      |> Workflows.list_step_runs()
      |> Enum.filter(&String.starts_with?(&1.step_name, "m/fail["))

    # FlakyTwice fails twice then succeeds; under :retry every fork ends completed
    # (with no retry it would fail on the first attempt).
    assert length(fork_rows) == 3
    assert Enum.all?(fork_rows, &(&1.status == "completed"))

    aggregate = finished.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "m"))
    assert aggregate.results["errors"] == []
    assert length(aggregate.results["results"]) == 3
  end

  # --- chunking + delivery (2.1) --------------------------------------------
  #
  # `EmitNumbers` emits [1,2,3,4,5]; `CaptureValue` echoes whatever is delivered
  # under `value`. `field: "value"` + `delivery` controls the fan-out unit/shape.

  defp delivery_workflow(extra_params) do
    base = %{
      "over" => "nums",
      "field" => "value",
      "body" => [
        %{
          "name" => "cap",
          "type" => "action",
          "module" => "Zaq.Engine.Workflows.Test.CaptureValue",
          "params" => %{}
        }
      ]
    }

    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "MapDelivery #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{
            name: "emit",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.EmitNumbers",
            params: %{},
            index: 0
          },
          %{name: "m", type: "map", params: Map.merge(base, extra_params), index: 1}
        ],
        edges: [%{from: "emit", to: "m"}]
      })

    wf
  end

  defp fork_rows(run_id) do
    run_id
    |> Workflows.list_step_runs()
    |> Enum.filter(&String.starts_with?(&1.step_name, "m/cap["))
    |> Enum.sort_by(& &1.step_name)
  end

  test ":list delivery + chunk_size 2 — one fork per chunk, body receives the chunk" do
    {:ok, finished} =
      Workflows.create_and_start_run(
        delivery_workflow(%{"delivery" => "list", "chunk_size" => 2}),
        @source_event
      )

    assert finished.status == "completed"

    rows = fork_rows(finished.id)
    # 5 items / size 2 ⇒ 3 chunks ⇒ 3 forks
    assert length(rows) == 3
    assert Enum.map(rows, & &1.results["captured"]) == [[1, 2], [3, 4], [5]]
  end

  test ":item delivery — one fork per item, body receives the scalar item" do
    {:ok, finished} =
      Workflows.create_and_start_run(delivery_workflow(%{"delivery" => "item"}), @source_event)

    assert finished.status == "completed"

    rows = fork_rows(finished.id)
    assert length(rows) == 5
    assert Enum.map(rows, & &1.results["captured"]) == [1, 2, 3, 4, 5]
  end

  test ":list delivery with no chunk_size — one single-element chunk per item" do
    {:ok, finished} =
      Workflows.create_and_start_run(delivery_workflow(%{"delivery" => "list"}), @source_event)

    assert finished.status == "completed"

    rows = fork_rows(finished.id)
    assert length(rows) == 5
    assert Enum.map(rows, & &1.results["captured"]) == [[1], [2], [3], [4], [5]]
  end

  # --- progress events (Part 3, Step 7) -------------------------------------

  defp drain_broadcasts(acc \\ []) do
    receive do
      {:bcast, msg} -> drain_broadcasts([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a map run broadcasts per-fork progress and a final aggregate event" do
    test_pid = self()

    stub(Zaq.NodeRouterMock, :dispatch, fn
      %Zaq.Event{request: {:broadcast, _topic, msg}} = event ->
        send(test_pid, {:bcast, msg})
        event

      %Zaq.Event{} = event ->
        event
    end)

    {:ok, finished} = Workflows.create_and_start_run(map_workflow(), @source_event)
    assert finished.status == "completed"

    step_updates =
      for {:step_updated, sr} <- drain_broadcasts(), do: {sr.step_name, sr.status}

    # progress derives from per-fork StepRun completions as items finish...
    assert {"m/ok[0]", "completed"} in step_updates
    assert {"m/ok[1]", "completed"} in step_updates
    assert {"m/ok[2]", "completed"} in step_updates

    # ...and the aggregate map row completing is the final "all done" event.
    assert {"m", "completed"} in step_updates
  end

  # --- sequential run-driver determinism (Part 3, Step 8 / D-A2) ------------

  test "forks resolve sequentially in deterministic index order" do
    # Sequential execution (no async opt-in yet) must keep the aggregate summary
    # ordered by fan-out index across repeated runs.
    orders =
      for _ <- 1..3 do
        {:ok, finished} =
          Workflows.create_and_start_run(
            delivery_workflow(%{"delivery" => "item"}),
            @source_event
          )

        aggregate =
          finished.id |> Workflows.list_step_runs() |> Enum.find(&(&1.step_name == "m"))

        Enum.map(aggregate.results["results"], & &1["index"])
      end

    assert orders == [[0, 1, 2, 3, 4], [0, 1, 2, 3, 4], [0, 1, 2, 3, 4]]
  end

  # --- max_items guard (Part 3, Step 10 / D-A8) -----------------------------

  defp max_items_workflow(max_items) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "MapLimit #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{
            name: "emit",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.EmitItems",
            params: %{},
            index: 0
          },
          %{
            name: "m",
            type: "map",
            params: %{
              "over" => "items",
              "max_items" => max_items,
              "body" => [
                %{
                  "name" => "ok",
                  "type" => "action",
                  "module" => "Zaq.Engine.Workflows.Test.OkAction",
                  "params" => %{}
                }
              ]
            },
            index: 1
          }
        ],
        edges: [%{from: "emit", to: "m"}]
      })

    wf
  end

  test "a collection over max_items is rejected with {:map_over_limit, …}" do
    # EmitItems emits 3 items; cap of 2 ⇒ over limit, no unbounded fan-out.
    assert {:error, {:map_over_limit, "m", 3, 2}} =
             Workflows.create_and_start_run(max_items_workflow(2), @source_event)
  end

  test "a collection within max_items fans out normally" do
    assert {:ok, %WorkflowRun{status: "completed"}} =
             Workflows.create_and_start_run(max_items_workflow(3), @source_event)
  end

  # --- post_process (2.3) ---------------------------------------------------

  test "post_process runs as a per-fork tail after the body" do
    base = %{
      "over" => "nums",
      "field" => "value",
      "delivery" => "item",
      "body" => [
        %{
          "name" => "cap",
          "type" => "action",
          "module" => "Zaq.Engine.Workflows.Test.CaptureValue",
          "params" => %{}
        }
      ],
      "post_process" => [
        %{
          "name" => "done",
          "type" => "action",
          "module" => "Zaq.Engine.Workflows.Test.MarkDone",
          "params" => %{}
        }
      ]
    }

    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "MapPost #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{
            name: "emit",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.EmitNumbers",
            params: %{},
            index: 0
          },
          %{name: "m", type: "map", params: base, index: 1}
        ],
        edges: [%{from: "emit", to: "m"}]
      })

    {:ok, finished} = Workflows.create_and_start_run(wf, @source_event)
    assert finished.status == "completed"

    names = finished.id |> Workflows.list_step_runs() |> Enum.map(& &1.step_name)

    # both the body fork and the post_process tail fork exist, per item
    for i <- 0..4 do
      assert "m/cap[#{i}]" in names
      assert "m/done[#{i}]" in names
    end

    post_rows =
      finished.id
      |> Workflows.list_step_runs()
      |> Enum.filter(&String.starts_with?(&1.step_name, "m/done["))

    assert length(post_rows) == 5
    assert Enum.all?(post_rows, &(&1.status == "completed"))
    assert Enum.all?(post_rows, &(&1.results["done"] == true))
  end

  # --- resume (Part 4 / D-A6) -----------------------------------------------

  test "resume skips already-completed forks without duplicating rows" do
    {:ok, finished} = Workflows.create_and_start_run(map_workflow(), @source_event)
    assert finished.status == "completed"

    before_rows =
      finished.id |> Workflows.list_step_runs() |> Enum.map(& &1.step_name) |> Enum.sort()

    # Re-drive the DAG via resume: StepRunner must skip every already-completed
    # fork + aggregate row, so no per-fork work re-runs and no rows are duplicated.
    {:ok, paused} = Workflows.update_run(finished, %{status: "paused"})
    {:ok, resumed} = Workflows.resume_run(paused)

    assert resumed.status == "completed"

    after_rows =
      resumed.id |> Workflows.list_step_runs() |> Enum.map(& &1.step_name) |> Enum.sort()

    assert after_rows == before_rows
  end

  # --- composition stack (Part 4) -------------------------------------------
  #
  # A `map` whose body contains a `workflow`-ref node is NOT yet supported: the
  # map body lowering only accepts `action`/`agent` nodes. This pins the current
  # contract (a clean build error, not a silent miscompile). Recursing
  # `Composition.expand` into map bodies is a documented follow-up.

  test "a map body with a workflow-ref node fails the build cleanly" do
    snapshot = %{
      "nodes" => [
        %{
          "name" => "emit",
          "type" => "action",
          "module" => "Zaq.Engine.Workflows.Test.EmitItems",
          "params" => %{},
          "index" => 0
        },
        %{
          "name" => "m",
          "type" => "map",
          "params" => %{
            "over" => "items",
            "body" => [
              %{"name" => "sub", "type" => "workflow", "params" => %{"workflow_ref" => "x"}}
            ]
          },
          "index" => 1
        }
      ],
      "edges" => [%{"from" => "emit", "to" => "m"}]
    }

    assert {:error, {:unsupported_map_body_node_type, "workflow"}} =
             DagBuilder.build(snapshot, [])
  end
end
