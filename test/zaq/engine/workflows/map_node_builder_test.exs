defmodule Zaq.Engine.Workflows.MapNodeBuilderTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.FactLookup
  alias Zaq.Engine.Workflows.MapNodeBuilder

  @capture_module "Zaq.Engine.Workflows.Test.CaptureValue"

  test "collection preserves only the parent cascade for successful, failed and empty batches" do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)

    for {items, fail?} <- [{[1, 2], false}, {[1, 2], true}, {[], false}] do
      [capture] = body()
      process = [Map.put(capture, "mapping", %{"value" => "value"})]

      process =
        if fail?,
          do:
            process ++
              [
                %{
                  "name" => "fail",
                  "type" => "action",
                  "module" => "Zaq.Engine.Workflows.Test.ErrorAction",
                  "params" => %{}
                }
              ],
          else: process

      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "Collect cascade",
          status: "active",
          nodes: [
            %{
              name: "batch",
              type: "action",
              index: 0,
              module: "Zaq.Agent.Tools.Workflow.Batch",
              params: %{"delivery" => "item", "process" => process}
            },
            %{name: "after_batch", type: "action", index: 1, module: @capture_module, params: %{}}
          ],
          edges: [%{from: "batch", to: "after_batch", mapping: %{"value" => "start.marker"}}]
        })

      source = %{assigns: %{input: %{items: items, marker: "parent"}}}
      assert {:ok, run} = Workflows.create_and_start_run(workflow, source)
      assert run.status == "completed"
      steps = Workflows.list_step_runs(run.id)
      collected = Enum.find(steps, &(&1.step_name == "batch")).results
      assert collected["count"] == length(items)
      assert length(collected["errors"]) == if(fail?, do: length(items), else: 0)
      assert Enum.sort(Map.keys(collected["__cascade__"])) == ["batch", "start"]
      assert Enum.find(steps, &(&1.step_name == "after_batch")).results["captured"] == "parent"

      assert length(Enum.filter(steps, &String.starts_with?(&1.step_name, "batch/"))) ==
               length(items) * if(fail?, do: 2, else: 1)
    end
  end

  property "body mappings retain parent and earlier item results across intervening nodes and resume" do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)

    check all(values <- uniq_list_of(integer(), min_length: 2, max_length: 5), max_runs: 10) do
      {:ok, workflow} = Workflows.create_workflow(%{name: "Cascade", status: "draft"})
      {:ok, run} = Workflows.create_run(workflow, %{})

      params = %{
        "over" => "items",
        "delivery" => "item",
        "field" => "value",
        "body" =>
          body() ++
            [
              %{
                "name" => "intervening",
                "type" => "action",
                "module" => "Zaq.Engine.Workflows.Test.MarkDone",
                "params" => %{}
              },
              %{
                "name" => "restore",
                "type" => "action",
                "module" => @capture_module,
                "params" => %{},
                "mapping" => %{"value" => "capture.captured"}
              }
            ],
        "post_process" => [
          %{
            "name" => "parent",
            "type" => "action",
            "module" => @capture_module,
            "params" => %{},
            "mapping" => %{"value" => "start.marker"}
          }
        ]
      }

      assert {:ok, spec} = MapNodeBuilder.build_spec("batch", params, 0, run.id)

      facts =
        spec.extract.work.(%{
          items: values,
          __cascade__: %{start: %{marker: "parent"}, capture: %{captured: "parent collision"}}
        })

      for {fact, value} <- Enum.zip(facts, values) do
        result = spec.last_body.work.(fact)
        assert {:ok, ^value} = FactLookup.fetch(result, "restore.captured")
        assert {:ok, "parent"} = FactLookup.fetch(result, "parent.captured")
        assert map_size(result.__cascade__) == 9

        # Completed steps are read back from JSONB on the second execution.
        resumed = spec.last_body.work.(fact)
        assert {:ok, ^value} = FactLookup.fetch(resumed, "restore.captured")
        assert {:ok, "parent"} = FactLookup.fetch(resumed, "parent.captured")
      end

      assert length(Workflows.list_step_runs(run.id)) == length(values) * 4
    end
  end

  test "rejects malformed body mappings before execution" do
    [capture] = body()
    params = %{"over" => "items", "body" => [Map.put(capture, "mapping", %{"value" => 123})]}

    assert {:error, {:invalid_body_mapping, "capture"}} =
             MapNodeBuilder.build_spec("batch", params, 0, nil)

    assert {:error, message} =
             Zaq.Engine.Workflows.Step.Node.validate_node_map(hd(params["body"]))

    assert message =~ "mapping"
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
end
