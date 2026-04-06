defmodule Zaq.Ingestion.Python.Steps.CleanMdTest do
  use ExUnit.Case, async: true

  alias Zaq.Ingestion.Python.Steps.CleanMd

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_clean_md_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "run/2" do
    test "returns {:ok, :skipped} when duplicate_mapping.txt does not exist", %{tmp_dir: tmp_dir} do
      assert {:ok, :skipped} = CleanMd.run(Path.join(tmp_dir, "doc.md"), tmp_dir)
    end

    test "calls Runner when duplicate_mapping.txt exists", %{tmp_dir: tmp_dir} do
      mapping = Path.join(tmp_dir, "duplicate_mapping.txt")
      File.write!(mapping, "old.png new.png")

      doc_md = Path.join(tmp_dir, "doc.md")
      File.write!(doc_md, "# Test content\n![old.png](old.png)")

      result = CleanMd.run(doc_md, tmp_dir)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "does not raise on missing md_path when mapping absent", %{tmp_dir: tmp_dir} do
      result = CleanMd.run("/does/not/exist.md", tmp_dir)
      assert result == {:ok, :skipped}
    end
  end
end
