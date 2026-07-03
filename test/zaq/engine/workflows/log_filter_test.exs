defmodule Zaq.Engine.Workflows.LogFilterTest do
  @moduledoc """
  Unit tests for the `:logger` primary filter that drops expected edge-condition
  prune logs, plus an end-to-end check that firing a fork (which prunes one branch
  via `ConditionNotMet`) no longer emits the framework error/warning lines.
  """
  use Zaq.DataCase, async: false

  import ExUnit.CaptureLog

  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.LogFilter
  alias Zaq.Event

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  @marker_msg ~s(Action Zaq.Engine.Workflows.Steps.EdgeStep failed: %{op: :empty, ) <>
                ~s(__struct__: "Zaq.Engine.Workflows.Conditions.ConditionNotMet"})
  @genuine_msg "Action SomeOther failed: %{__struct__: RuntimeError, message: \"boom\"}"

  describe "filter/2" do
    test "drops an :error event carrying the ConditionNotMet marker" do
      assert LogFilter.filter(%{level: :error, msg: {:string, @marker_msg}}, []) == :stop
    end

    test "drops a :warning event carrying the marker" do
      assert LogFilter.filter(%{level: :warning, msg: {:string, @marker_msg}}, []) == :stop
    end

    test "ignores an :error event without the marker (genuine failures stay loud)" do
      assert LogFilter.filter(%{level: :error, msg: {:string, @genuine_msg}}, []) == :ignore
    end

    test "ignores non-error/warning levels even if they mention the marker" do
      for level <- [:info, :debug, :notice] do
        assert LogFilter.filter(%{level: level, msg: {:string, @marker_msg}}, []) == :ignore
      end
    end

    test "handles the {format, args} and {:report, _} message shapes" do
      assert LogFilter.filter(%{level: :error, msg: {~c"~ts", [@marker_msg]}}, []) == :stop
      assert LogFilter.filter(%{level: :error, msg: {~c"~ts", [@genuine_msg]}}, []) == :ignore

      assert LogFilter.filter(%{level: :error, msg: {:report, %{error: @marker_msg}}}, []) ==
               :stop
    end

    test "never raises on a malformed message (fails open)" do
      assert LogFilter.filter(%{level: :error, msg: {:weird, :shape}}, []) == :ignore
    end

    test "fails open when rendering format args or chardata raises" do
      assert LogFilter.filter(%{level: :error, msg: {~c"~ts ~ts", ["one"]}}, []) == :ignore
      assert LogFilter.filter(%{level: :error, msg: {:string, {:not_chardata}}}, []) == :ignore
    end
  end

  describe "install/0" do
    test "is idempotent" do
      assert LogFilter.install() == :ok
      assert LogFilter.install() == :ok
    end

    test "swallows unexpected logger registration errors" do
      assert LogFilter.install(fn :zaq_workflow_condition_not_met, {_fun, []} ->
               {:error, :handler_not_added}
             end) == :ok
    end
  end

  describe "end-to-end: a pruned fork branch emits no ConditionNotMet log" do
    @ok_module "Zaq.Engine.Workflows.Test.OkAction"
    @trigger_event "engine:log_filter_test"

    test "firing a fork prunes the losing branch silently" do
      # The filter is installed at app boot; confirm it's active for this run.
      :ok = LogFilter.install()

      nodes = [
        %{name: "have_context", type: "action", module: @ok_module, params: %{}, index: 0},
        %{name: "generate", type: "action", module: @ok_module, params: %{}, index: 1}
      ]

      # Content present → not_empty wins, empty branch is pruned (raises ConditionNotMet).
      edges = [
        %{
          from: "start",
          to: "have_context",
          condition: %{"field" => "start.ctx", "op" => "not_empty"}
        },
        %{from: "start", to: "generate", condition: %{"field" => "start.ctx", "op" => "empty"}}
      ]

      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "Log Filter Fork #{System.unique_integer([:positive])}",
          status: "active",
          nodes: nodes,
          edges: edges
        })

      {:ok, trigger} = Workflows.create_trigger(%{event_name: @trigger_event, enabled: true})
      {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)

      event = %Event{
        request: %{"ctx" => "present"},
        next_hop: nil,
        name: :start,
        trace_id: Ecto.UUID.generate(),
        assigns: %{}
      }

      log =
        capture_log(fn ->
          :ok = TriggerNode.fire(@trigger_event, event)
        end)

      refute log =~ "ConditionNotMet"
      refute log =~ "Runnable failed"

      # And routing still worked: losing branch pruned, winning branch ran.
      by_name = workflow.id |> Workflows.list_runs() |> List.first() |> then(&status_map/1)
      assert by_name["have_context"] == "completed"
      refute by_name["generate"] == "completed"
    end
  end

  defp status_map(run) do
    run.id |> Workflows.list_step_runs() |> Map.new(&{&1.step_name, &1.status})
  end
end
