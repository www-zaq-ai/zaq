defmodule Zaq.Storage.SourcePathTest do
  # async: false — these tests mutate the global `Application.put_env(:zaq, Zaq.Storage,
  # base_path: ...)`, which the "default" volume resolves at runtime. Running async would leak
  # the transient base_path into concurrent tests (e.g. DirectorySnapshotTest), making them list
  # the wrong directory. Every other base_path-mutating module is async: false for this reason.
  use ExUnit.Case, async: false

  alias Zaq.Storage.{FileExplorer, SourcePath}

  @test_base "test/tmp/source_path"

  setup do
    original = Application.get_env(:zaq, Zaq.Storage)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Storage, original || [])
    end)

    :ok
  end

  describe "remap_source/3" do
    test "preserves a matching volume prefix" do
      assert SourcePath.remap_source("documents/old/file.md", "documents", "./new/file.md") ==
               "documents/new/file.md"
    end

    test "returns a relative path when the existing source is not volume-prefixed" do
      assert SourcePath.remap_source("old/file.md", "documents", "./new/file.md") ==
               "new/file.md"
    end

    test "returns a relative path when the existing source is nil" do
      assert SourcePath.remap_source(nil, "documents", "./new/file.md") == "new/file.md"
    end
  end

  describe "legacy_folder_prefixes/3" do
    test "returns empty list when volume_name is not in volumes map" do
      # line 139: Map.get(volumes, volume_name) -> nil
      result = SourcePath.legacy_folder_prefixes("nonexistent", "some/path", %{"other" => "/tmp"})
      assert result == []
    end

    test "returns legacy prefix when volume is known and prefix differs from candidates" do
      File.mkdir_p!(@test_base)
      Application.put_env(:zaq, Zaq.Storage, base_path: @test_base)
      volumes = %{"default" => @test_base}

      result = SourcePath.legacy_folder_prefixes("default", "docs", volumes)

      expanded = Path.expand(@test_base)
      expected_legacy = "default/" <> String.trim_leading(Path.join(expanded, "docs"), "/")

      # If legacy prefix is not among the standard candidates it should be returned
      standard = SourcePath.source_candidates("default", "docs")

      if expected_legacy in standard do
        assert result == []
      else
        assert expected_legacy in result
      end
    end
  end

  describe "absolute_to_source/1 in multi-volume mode" do
    test "returns a volume-prefixed path for a file inside a configured volume" do
      root =
        Path.join(
          System.tmp_dir!(),
          "zaq_source_path_documents_#{System.unique_integer([:positive])}"
        )

      file_path = Path.join(root, "nested/report.md")
      Application.put_env(:zaq, Zaq.Storage, volumes: %{"documents" => root})

      assert {:ok, "documents/nested/report.md"} = SourcePath.absolute_to_source(file_path)
    end

    test "falls back to basename when path is outside all configured volumes" do
      # line 95: find_volume_for_path returns nil
      tmp = System.tmp_dir!()
      vol_path = Path.join(tmp, "zaq_source_path_vol_#{System.unique_integer([:positive])}")
      File.mkdir_p!(vol_path)

      Application.put_env(:zaq, Zaq.Storage, volumes: %{"testvol" => vol_path})

      outside_path = Path.join(tmp, "outside_vol/somefile.txt")

      assert {:ok, source} = SourcePath.absolute_to_source(outside_path)
      assert source == "somefile.txt"
    after
      :ok
    end
  end

  describe "absolute_to_source/1 in single-volume mode" do
    test "returns an empty source for the root path" do
      Application.put_env(:zaq, Zaq.Storage, base_path: "/")

      assert {:ok, ""} = SourcePath.absolute_to_source("/")
    end

    test "returns path relative to root base_path" do
      Application.put_env(:zaq, Zaq.Storage, base_path: "/")

      assert {:ok, source} = SourcePath.absolute_to_source("/tmp/root-file.md")
      assert source == "tmp/root-file.md"
    end

    test "falls back to basename when path is outside the configured base" do
      # line 104: relative_to_root returns nil
      tmp = System.tmp_dir!()
      base = Path.join(tmp, "zaq_source_path_base_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      Application.put_env(:zaq, Zaq.Storage, base_path: base)

      outside_path = Path.join(tmp, "other_dir/myfile.txt")

      assert {:ok, source} = SourcePath.absolute_to_source(outside_path)
      assert source == "myfile.txt"
    end
  end

  describe "volume_root_for_absolute/1" do
    test "returns base_path when path is not under any volume" do
      # line 126: no volume root found -> FileExplorer.base_path()
      Application.put_env(:zaq, Zaq.Storage, base_path: @test_base)

      outside = "/tmp/completely_outside/file.txt"
      result = SourcePath.volume_root_for_absolute(outside)

      # Should fall back to the configured base path
      assert result == FileExplorer.base_path()
    end

    test "returns the matching volume root when path is inside a volume" do
      tmp = System.tmp_dir!()
      vol = Path.join(tmp, "vol_root_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(vol)
      Application.put_env(:zaq, Zaq.Storage, base_path: vol)

      inside = Path.join(vol, "subdir/file.txt")
      result = SourcePath.volume_root_for_absolute(inside)
      assert result == Path.expand(vol)
    end
  end
end
