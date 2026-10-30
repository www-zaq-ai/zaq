defmodule Zaq.Engine.Workflows.MapNodeBuilderTest do
  use Zaq.DataCase, async: true

  alias Runic.Workflow, as: RunicWorkflow
  alias Runic.Workflow.{Fact, Runnable}
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.{MapNodeBuilder, Step, Workflow}

  @capture_module "Zaq.Engine.Workflows.Test.CaptureValue"
  @hitl "Zaq.Engine.Workflows.Steps.HumanInTheLoop"

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp body do
    [
      %{
        "name" => "capture",
        "type" => "action",
        "module" => @capture_module,
        "params" => %{}
      }
    ]
  end

  defp build_spec(params) do
    params = Map.merge(%{"over" => "items", "body" => body()}, params)
    assert {:ok, spec} = MapNodeBuilder.build_spec("map_contacts", params, 2, nil)
    spec
  end

  describe "extract step" do
    test "returns an empty list for non-map input or non-binary over field" do
      spec = build_spec(%{})
      assert spec.extract.work.("not a map") == []

      spec = build_spec(%{"over" => :items})
      assert spec.extract.work.(%{"items" => [1]}) == []
    end

    test "stamps scalar items with map item metadata" do
      spec = build_spec(%{"over" => "missing_atom"})

      assert [
               %{"__map_item__" => "a", "__map_index__" => 0},
               %{"__map_item__" => "b", "__map_index__" => 1}
             ] = spec.extract.work.(%{"missing_atom" => ["a", "b"]})
    end

    test "wraps list delivery units under nil when the delivery field is not an existing atom" do
      spec =
        build_spec(%{
          "delivery" => "list",
          "field" => "definitely_not_an_existing_atom",
          "chunk_size" => 2
        })

      assert [%{nil => [1, 2], "__map_index__" => 0}] =
               spec.extract.work.(%{"items" => [1, 2]})
    end
  end

  describe "reduce step" do
    test "keeps scalar items and drops string-keyed or atom-keyed map error sentinels" do
      reducer = build_spec(%{}).reduce.fan_in.reducer

      assert [%{"index" => nil, "status" => "completed", "result" => "sent"}] =
               reducer.("sent", [])

      assert [] = reducer.(%{"__map_error__" => true, "__map_index__" => 0}, [])
      assert [] = reducer.(%{__map_error__: true, __map_index__: 1}, [])
    end
  end

  describe "fork executor" do
    test "an outer-Jido error without a durable failed cursor stops the map" do
      {:ok, run} = Workflows.create_run(one_item_hitl_map(), @source_event)

      {:ok, cursor} =
        Workflows.create_step_run(run, %{
          step_name: "m/review[0]",
          step_index: 0,
          status: "running"
        })

      # A pending approval paired with a completed cursor is deliberately inconsistent.
      # StepRunner rejects it before creating or persisting a failed fork cursor, which
      # exercises the outer-Jido error transport independently of paused recovery.
      {:ok, _completed_cursor} = Workflows.complete_step_run(cursor, %{})

      {:ok, _approval} =
        Workflows.ensure_pending_approval(%{
          workflow_run_id: run.id,
          step_name: "m/review[0]"
        })

      seeded =
        RunicWorkflow.invoke(
          run.prepared_dag,
          RunicWorkflow.root(),
          Fact.new(value: %{})
        )

      fork_runnable = execute_until_map_fork(seeded)

      assert fork_runnable.status == :failed
      assert fork_runnable.error
      refute map_error_sentinel?(fork_runnable)

      refute Enum.any?(Workflows.list_step_runs(run.id), fn step_run ->
               step_run.step_name == "m/review[0]" and
                 step_run.status in ["failed", "failed_fatal"]
             end)

      assert {:ok, finished} = Workflows.start_run(run)
      refute finished.status == "completed"
      assert Workflows.get_step_run_by_name(run.id, "m") == nil
    end

    test "a completed sibling cannot hide an outer map error without a failed cursor" do
      sibling =
        struct(Step.Node, %{
          name: "sibling",
          type: "action",
          module: "Zaq.Engine.Workflows.Test.OkAction",
          params: %{},
          index: 2
        })

      {:ok, run} = Workflows.create_run(one_item_hitl_map([sibling]), @source_event)

      {:ok, cursor} =
        Workflows.create_step_run(run, %{
          step_name: "m/review[0]",
          step_index: 0,
          status: "running"
        })

      # Use the same inconsistent approval/cursor boundary as the single-map case.
      # This time an independent leaf completes, so quiescence alone cannot prove
      # that the native Runic fork's exception reached the durable run outcome.
      {:ok, _} = Workflows.complete_step_run(cursor, %{})

      {:ok, approval} =
        Workflows.ensure_pending_approval(%{
          workflow_run_id: run.id,
          step_name: "m/review[0]"
        })

      assert {:ok, finished} = Workflows.start_run(run)
      assert Workflows.get_terminal_step_run(run.id, "sibling").status == "completed"
      assert Workflows.get_approval_by_token(approval.approval_token).status == "pending"
      assert finished.status in ["failed", "interrupted"]
      assert Workflows.get_run!(run.id).status == finished.status
    end

    test "a durable failed map item wins over a waiting item" do
      wf =
        Zaq.Repo.insert!(%Workflow{
          name: "Failed then waiting map #{System.unique_integer([:positive])}",
          status: "active",
          nodes: [
            struct(Step.Node, %{
              name: "emit",
              type: "action",
              module: "Zaq.Engine.Workflows.Test.EmitItems",
              params: %{},
              index: 0
            }),
            struct(Step.Node, %{
              name: "m",
              type: "map",
              params: %{
                "over" => "items",
                "strategy" => "fail_workflow",
                "body" => [
                  %{
                    "name" => "maybe_fail",
                    "type" => "action",
                    "module" => "Zaq.Engine.Workflows.Test.FailOddN",
                    "params" => %{}
                  },
                  %{"name" => "review", "type" => "action", "module" => @hitl, "params" => %{}}
                ]
              },
              index: 1
            })
          ],
          edges: [struct(Step.Edge, %{from: "emit", to: "m"})]
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)

      # Persist the first failed fork before dispatch. Runic may prepare fork
      # runnables in either order; both orders must honor the durable failure.
      {:ok, cursor} =
        Workflows.create_step_run(run, %{
          step_name: "m/maybe_fail[0]",
          step_index: 0,
          status: "running"
        })

      {:ok, _} = Workflows.fail_step_run(cursor, %{reason: "odd_n:1"})

      assert {:ok, run} = Workflows.start_run(run)
      assert Workflows.get_terminal_step_run(run.id, "m/maybe_fail[0]").status == "failed"
      assert Workflows.get_terminal_step_run(run.id, "m/review[1]").status == "waiting"
      assert run.status == "failed"
      assert Workflows.get_run!(run.id).status == "failed"

      approval = Workflows.get_step_approval(run.id, "m/review[1]")

      assert {:error, :not_waiting} =
               Workflows.approve_step(%{run | status: "waiting"}, approval, %{}, nil)

      assert Workflows.get_run!(run.id).status == "failed"
    end
  end

  defp one_item_hitl_map(extra_nodes \\ []) do
    Zaq.Repo.insert!(%Workflow{
      name: "Map fork failure #{System.unique_integer([:positive])}",
      status: "active",
      nodes:
        [
          struct(Step.Node, %{
            name: "emit",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.EmitIndexedItems",
            params: %{count: 1},
            index: 0
          }),
          struct(Step.Node, %{
            name: "m",
            type: "map",
            params: %{
              "over" => "items",
              "strategy" => "fail_workflow",
              "body" => [
                %{"name" => "review", "type" => "action", "module" => @hitl, "params" => %{}}
              ]
            },
            index: 1
          })
        ] ++ extra_nodes,
      edges: [struct(Step.Edge, %{from: "emit", to: "m"})]
    })
  end

  defp execute_until_map_fork(dag) do
    {prepared, runnables} = RunicWorkflow.prepare_for_dispatch(dag)

    result =
      Enum.reduce_while(runnables, {:continue, prepared}, fn runnable, {:continue, current} ->
        executed = RunicWorkflow.execute_runnable(runnable)

        if MapNodeBuilder.fork_executor?(runnable.node) do
          {:halt, {:found, executed}}
        else
          {:cont, {:continue, RunicWorkflow.apply_runnable(current, executed)}}
        end
      end)

    case result do
      {:found, %Runnable{} = runnable} ->
        runnable

      {:continue, next} when runnables != [] ->
        execute_until_map_fork(next)

      {:continue, _quiescent} ->
        flunk("workflow became quiescent before preparing the map fork runnable")
    end
  end

  defp map_error_sentinel?(%Runnable{result: %Fact{value: value}}) when is_map(value),
    do: Map.get(value, "__map_error__") == true or Map.get(value, :__map_error__) == true

  defp map_error_sentinel?(_runnable), do: false
end
