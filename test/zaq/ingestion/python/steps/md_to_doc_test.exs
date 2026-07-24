defmodule Zaq.Ingestion.Python.Steps.MdToDocTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zaq.Ingestion.Python.Steps.MdToDoc

  describe "run/2" do
    test "returns a tagged tuple (or string) when converting a single file" do
      result = MdToDoc.run("/tmp/report.md")

      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_binary(result)
    end

    test "does not raise on missing file paths" do
      result = MdToDoc.run("/does/not/exist.md")

      assert is_tuple(result) or is_binary(result)
    end

    test "accepts explicit output, format, and toc options without raising" do
      result = MdToDoc.run("/tmp/report.md", to: "pdf", output: "/tmp/report.pdf", toc: true)

      assert is_tuple(result) or is_binary(result)
    end
  end

  describe "run_folder/3" do
    test "returns a tagged tuple for folder conversion" do
      result = MdToDoc.run_folder("/tmp/markdown", "/tmp/documents")

      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_binary(result)
    end

    test "does not raise on missing folder paths" do
      result = MdToDoc.run_folder("/does/not/exist", "/also/missing", toc: true)

      assert is_tuple(result) or is_binary(result)
    end
  end
end
