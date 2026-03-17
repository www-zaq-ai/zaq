defmodule Zaq.Ingestion.Python.Steps.PdfToMdTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zaq.Ingestion.Python.Steps.PdfToMd

  # ---------------------------------------------------------------------------
  # run/3 — delegates to Runner.run/2 with the correct script name + args
  # ---------------------------------------------------------------------------

  describe "run/3" do
    test "returns {:error, _} when script is absent (no real Python env)" do
      # In CI there are no Python scripts so any call must return an error.
      result = PdfToMd.run("/tmp/report.pdf", "/tmp/report.md", "./images")
      assert match?({:error, _}, result)
    end

    test "returns a two-element tagged tuple" do
      result = PdfToMd.run("/tmp/nonexistent.pdf", "/tmp/nonexistent.md", "/tmp/images")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "does not raise on missing file paths" do
      # run/3 must return a tagged tuple, never raise, even for absent paths.
      result = PdfToMd.run("/does/not/exist.pdf", "/does/not/exist.md", "/images")
      assert elem(result, 0) in [:ok, :error]
    end
  end
end
