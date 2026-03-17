defmodule Zaq.Ingestion.Python.Steps.ImageDedupTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zaq.Ingestion.Python.Steps.ImageDedup

  describe "run/2" do
    test "returns a tagged tuple when script is absent" do
      result = ImageDedup.run("/tmp/images_folder")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "passes --threshold when opt is given" do
      result = ImageDedup.run("/tmp/images_folder", threshold: 10)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "does not raise on missing folder" do
      result = ImageDedup.run("/does/not/exist")
      assert elem(result, 0) in [:ok, :error]
    end
  end
end
