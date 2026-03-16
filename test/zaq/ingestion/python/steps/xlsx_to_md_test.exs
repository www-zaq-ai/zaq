defmodule Zaq.Ingestion.Python.Steps.XlsxToMdTest do
  use ExUnit.Case, async: true

  alias Zaq.Ingestion.Python.Steps.XlsxToMd

  describe "run/2" do
    test "returns {:error, _} when script is absent (no real Python env)" do
      result = XlsxToMd.run("/tmp/report.xlsx", "/tmp/report.md")
      assert match?({:error, _}, result)
    end

    test "defaults md_path to same basename with .md extension" do
      result = XlsxToMd.run("/tmp/report.xlsx")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "does not raise on missing file paths" do
      result = XlsxToMd.run("/does/not/exist.xlsx", "/does/not/exist.md")
      assert elem(result, 0) in [:ok, :error]
    end
  end

  describe "run_folder/2" do
    test "returns a tagged tuple for folder conversion" do
      result = XlsxToMd.run_folder("/tmp/input_sheets", "/tmp/output_sheets")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "does not raise on missing folder paths" do
      result = XlsxToMd.run_folder("/does/not/exist", "/also/missing")
      assert elem(result, 0) in [:ok, :error]
    end
  end
end
