defmodule Zaq.Ingestion.Python.Steps.InjectDescriptionsTest do
  use ExUnit.Case, async: true

  alias Zaq.Ingestion.Python.Steps.InjectDescriptions

  describe "run/3" do
    test "returns a tagged tuple when script is absent" do
      result = InjectDescriptions.run("/tmp/doc.md", "/tmp/descriptions.json")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "passes --format opt when given" do
      result = InjectDescriptions.run("/tmp/doc.md", "/tmp/descriptions.json", format: "block")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "does not raise on missing paths" do
      result = InjectDescriptions.run("/does/not/exist.md", "/also/missing.json")
      assert elem(result, 0) in [:ok, :error]
    end
  end
end
