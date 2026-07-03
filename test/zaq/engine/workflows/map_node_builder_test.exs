defmodule Zaq.Engine.Workflows.MapNodeBuilderTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows.MapNodeBuilder

  @capture_module "Zaq.Engine.Workflows.Test.CaptureValue"

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
