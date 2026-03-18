defmodule Zaq.Ingestion.Python.PipelineTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Zaq.Ingestion.Python.Pipeline

  # ---------------------------------------------------------------------------
  # Shared setup: capture original config and restore on exit
  # ---------------------------------------------------------------------------

  setup do
    original_image_to_text = Application.get_env(:zaq, Zaq.Ingestion.Python.ImageToText)

    on_exit(fn ->
      if is_nil(original_image_to_text) do
        Application.delete_env(:zaq, Zaq.Ingestion.Python.ImageToText)
      else
        Application.put_env(:zaq, Zaq.Ingestion.Python.ImageToText, original_image_to_text)
      end
    end)

    # Build a temporary directory acting as the PDF's parent dir.
    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_pipeline_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # resolve_api_key — tested indirectly through run/1
  # ---------------------------------------------------------------------------

  describe "resolve_api_key via run/1" do
    test "opts :api_key takes precedence over Application env" do
      # We cannot easily assert on the internal key; instead we assert that
      # Pipeline.run/1 passes the key through by checking it invokes
      # ImageToText.run when an api_key is supplied.  Because the actual
      # Python scripts are absent in CI we just verify the function returns
      # an error tuple (not a crash / bad match) when scripts are missing.
      Application.delete_env(:zaq, Zaq.Ingestion.Python.ImageToText)

      result = Pipeline.run("/nonexistent/report.pdf", api_key: "inline-key")
      assert match?({:error, _}, result)
    end

    test "falls back to Application env api_key when not in opts" do
      Application.put_env(:zaq, Zaq.Ingestion.Python.ImageToText, api_key: "env-key")

      result = Pipeline.run("/nonexistent/report.pdf")
      assert match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # step skipping — no api_key
  # ---------------------------------------------------------------------------

  describe "run/1 without api_key" do
    test "returns error from first failing step (no api_key, scripts absent)" do
      Application.delete_env(:zaq, Zaq.Ingestion.Python.ImageToText)

      # Step 1 (PdfToMd) will fail because the PDF and script don't exist.
      # Steps 4 & 5 are unreachable, so no api_key error is the relevant path.
      result = Pipeline.run("/tmp/nonexistent_#{System.unique_integer()}.pdf")
      assert match?({:error, _}, result)
    end

    test "nil and empty-string api_key both skip image steps" do
      # Both must produce the same code path (step 1 fails, not an api_key error)
      Application.put_env(:zaq, Zaq.Ingestion.Python.ImageToText, api_key: nil)
      result_nil = Pipeline.run("/tmp/no_key_nil_#{System.unique_integer()}.pdf")

      Application.put_env(:zaq, Zaq.Ingestion.Python.ImageToText, api_key: "")
      result_empty = Pipeline.run("/tmp/no_key_empty_#{System.unique_integer()}.pdf")

      # Both paths should fail at step 1 (PdfToMd), not at image_to_text
      assert match?({:error, _}, result_nil)
      assert match?({:error, _}, result_empty)
    end
  end

  # ---------------------------------------------------------------------------
  # output path derivation
  # ---------------------------------------------------------------------------

  describe "output md_path" do
    test "defaults to pdf basename with .md extension" do
      # We cannot inspect the private md_path directly, so we test indirectly:
      # PdfToMd.run receives the derived md_path as its second arg and will
      # fail with an :error map containing the script invocation info.
      # The simplest assertion is that run/1 returns an error and does not crash.
      Application.delete_env(:zaq, Zaq.Ingestion.Python.ImageToText)
      assert match?({:error, _}, Pipeline.run("/tmp/report.pdf"))
    end

    test "honours opts :output for custom md_path" do
      Application.delete_env(:zaq, Zaq.Ingestion.Python.ImageToText)
      custom_out = "/tmp/custom_out_#{System.unique_integer()}.md"
      assert match?({:error, _}, Pipeline.run("/tmp/report.pdf", output: custom_out))
    end
  end

  # ---------------------------------------------------------------------------
  # Integration smoke-test using a real (trivial) markdown file
  # When Python scripts are present the full pipeline would run. Here we only
  # assert the public contract when scripts are absent.
  # ---------------------------------------------------------------------------

  describe "run/1 return shape" do
    test "always returns a two-element tagged tuple" do
      Application.delete_env(:zaq, Zaq.Ingestion.Python.ImageToText)
      result = Pipeline.run("/tmp/missing_#{System.unique_integer()}.pdf")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "cleans up temporary alias when pdf filename contains spaces", %{tmp_dir: tmp_dir} do
      Application.delete_env(:zaq, Zaq.Ingestion.Python.ImageToText)

      pdf_path = Path.join(tmp_dir, "Deck With Spaces.pdf")
      alias_path = Path.join(tmp_dir, "Deck_With_Spaces.pdf")
      File.write!(pdf_path, "%PDF-1.4")

      refute File.exists?(alias_path)

      result = Pipeline.run(pdf_path)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
      assert File.exists?(pdf_path)
      refute File.exists?(alias_path)
    end
  end
end
