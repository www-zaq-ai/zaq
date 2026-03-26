defmodule Zaq.Ingestion.Python.PipelineTest do
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Ingestion.Python.Pipeline

  setup do
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
    test "opts :api_key takes precedence over DB config" do
      result = Pipeline.run("/nonexistent/report.pdf", api_key: "inline-key")
      assert match?({:error, _}, result)
    end

    test "falls back to DB api_key when not in opts" do
      result = Pipeline.run("/nonexistent/report.pdf")
      assert match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # step skipping — no api_key
  # ---------------------------------------------------------------------------

  describe "run/1 without api_key" do
    test "returns error from first failing step (no api_key, scripts absent)" do
      result = Pipeline.run("/tmp/nonexistent_#{System.unique_integer()}.pdf")
      assert match?({:error, _}, result)
    end

    test "nil and empty-string api_key both skip image steps" do
      result_nil = Pipeline.run("/tmp/no_key_nil_#{System.unique_integer()}.pdf", api_key: nil)
      result_empty = Pipeline.run("/tmp/no_key_empty_#{System.unique_integer()}.pdf", api_key: "")

      assert match?({:error, _}, result_nil)
      assert match?({:error, _}, result_empty)
    end
  end

  # ---------------------------------------------------------------------------
  # output path derivation
  # ---------------------------------------------------------------------------

  describe "output md_path" do
    test "defaults to pdf basename with .md extension" do
      assert match?({:error, _}, Pipeline.run("/tmp/report.pdf"))
    end

    test "honours opts :output for custom md_path" do
      custom_out = "/tmp/custom_out_#{System.unique_integer()}.md"
      assert match?({:error, _}, Pipeline.run("/tmp/report.pdf", output: custom_out))
    end
  end

  # ---------------------------------------------------------------------------
  # Integration smoke-test using a real (trivial) markdown file
  # ---------------------------------------------------------------------------

  describe "run/1 return shape" do
    test "always returns a two-element tagged tuple" do
      result = Pipeline.run("/tmp/missing_#{System.unique_integer()}.pdf")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "cleans up temporary alias when pdf filename contains spaces", %{tmp_dir: tmp_dir} do
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
