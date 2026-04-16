defmodule Zaq.Ingestion.Python.PipelineStripImageRefsTest do
  use ExUnit.Case, async: true

  # Regression guard for Docker /tmp 404s.
  # pdf_to_md.py embeds absolute /tmp paths in the output markdown.
  # Phoenix does not serve /tmp, so those refs must be stripped from
  # the final .md before the pipeline deletes the images directory.

  alias Zaq.Ingestion.Python.Pipeline

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_strip_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "strip_local_image_refs/1" do
    test "removes local absolute-path image references from markdown", %{tmp_dir: tmp_dir} do
      md_path = Path.join(tmp_dir, "doc.md")

      File.write!(md_path, """
      # Report

      Some text here.

      ![Figure 1](/tmp/zaq_images_1234/doc/doc-p1-scan1.png)

      More text.

      ![Figure 2](/tmp/zaq_images_1234/doc/doc-p2-scan2.png)
      """)

      Pipeline.strip_local_image_refs(md_path)

      content = File.read!(md_path)
      refute content =~ ~r/!\[.*\]\(\/tmp\//
      assert content =~ "Some text here."
      assert content =~ "More text."
    end

    test "leaves external and relative image refs untouched", %{tmp_dir: tmp_dir} do
      md_path = Path.join(tmp_dir, "doc.md")

      File.write!(md_path, """
      ![Logo](https://example.com/logo.png)
      ![Relative](images/chart.png)
      ![Local](/tmp/zaq_images_9999/doc/doc-p1.png)
      """)

      Pipeline.strip_local_image_refs(md_path)

      content = File.read!(md_path)
      assert content =~ "https://example.com/logo.png"
      assert content =~ "images/chart.png"
      refute content =~ "/tmp/zaq_images_9999"
    end

    test "is a no-op when markdown has no image references", %{tmp_dir: tmp_dir} do
      md_path = Path.join(tmp_dir, "plain.md")
      original = "# Title\n\nJust text, no images.\n"
      File.write!(md_path, original)

      Pipeline.strip_local_image_refs(md_path)

      assert File.read!(md_path) == original
    end

    test "handles non-existent file without raising", %{tmp_dir: tmp_dir} do
      md_path = Path.join(tmp_dir, "missing.md")
      assert :ok = Pipeline.strip_local_image_refs(md_path)
    end
  end
end
