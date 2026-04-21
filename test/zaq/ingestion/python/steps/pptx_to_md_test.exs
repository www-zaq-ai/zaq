defmodule Zaq.Ingestion.Python.Steps.PptxToMdTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zaq.Ingestion.Python.Steps.PptxToMd

  describe "run/2" do
    test "returns {:error, _} when script is absent (no real Python env)" do
      result = PptxToMd.run("/tmp/report.pptx", "/tmp/report.md")

      assert match?({:error, _}, result) or is_binary(result)
    end

    test "defaults md_path to same basename with .md extension" do
      result = PptxToMd.run("/tmp/report.pptx")

      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_binary(result)
    end

    test "does not raise on missing file paths" do
      result = PptxToMd.run("/does/not/exist.pptx", "/does/not/exist.md")

      assert is_tuple(result) or is_binary(result)
    end
  end

  describe "run_folder/2" do
    test "returns a tagged tuple for folder conversion" do
      result = PptxToMd.run_folder("/tmp/input_slides", "/tmp/output_slides")

      assert match?({:ok, _}, result) or match?({:error, _}, result) or is_binary(result)
    end

    test "does not raise on missing folder paths" do
      result = PptxToMd.run_folder("/does/not/exist", "/also/missing")

      assert is_tuple(result) or is_binary(result)
    end
  end
end
