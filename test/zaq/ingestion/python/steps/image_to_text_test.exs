defmodule Zaq.Ingestion.Python.Steps.ImageToTextTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zaq.Ingestion.Python.Steps.ImageToText

  # ---------------------------------------------------------------------------
  # run/3 — delegates to Runner.run/2 with flag-style args
  # ---------------------------------------------------------------------------

  describe "run/3" do
    test "returns {:error, _} when script is absent (no real Python env)" do
      result = ImageToText.run("/tmp/images", "/tmp/descriptions.json", "test-api-key")
      assert match?({:error, _}, result)
    end

    test "returns a two-element tagged tuple" do
      result =
        ImageToText.run(
          "/tmp/nonexistent_images",
          "/tmp/nonexistent_descriptions.json",
          "some-key"
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "does not raise for any string arguments" do
      result = ImageToText.run("", "", "")
      assert elem(result, 0) in [:ok, :error]
    end
  end

  describe "run_single/3" do
    test "returns {:error, _} when script is absent (no real Python env)" do
      result = ImageToText.run_single("/tmp/image.png", "/tmp/descriptions.json", "test-api-key")
      assert match?({:error, _}, result)
    end

    test "returns a two-element tagged tuple" do
      result = ImageToText.run_single("/tmp/nonexistent.jpg", "/tmp/output.json", "some-key")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
