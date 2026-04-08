defmodule Zaq.Ingestion.FileExplorerTest do
  use ExUnit.Case, async: false

  alias Zaq.Ingestion.FileExplorer

  @test_base "test/tmp/file_explorer"

  setup do
    File.rm_rf!(@test_base)
    File.mkdir_p!(@test_base)

    # Override config to use test directory
    original = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(@test_base)
    end)

    :ok
  end

  describe "resolve_path/1" do
    test "resolves a valid relative path" do
      assert {:ok, path} = FileExplorer.resolve_path("docs")
      assert String.ends_with?(path, "file_explorer/docs")
    end

    test "rejects path traversal" do
      assert {:error, :path_traversal} = FileExplorer.resolve_path("../../etc/passwd")
    end

    test "rejects sneaky traversal" do
      assert {:error, :path_traversal} = FileExplorer.resolve_path("foo/../../..")
    end
  end

  describe "resolve_path/1 with volumes configured" do
    setup do
      vol = Path.join(@test_base, "vol_resolve1")
      File.mkdir_p!(vol)
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base, volumes: %{"docs" => vol})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      %{vol: vol}
    end

    test "auto-resolves volume-prefixed path when volumes are configured", %{vol: vol} do
      # Simulates preview URL like /bo/preview/docs/file.pdf
      assert {:ok, path} = FileExplorer.resolve_path("docs/file.pdf")
      assert path == Path.join(Path.expand(vol), "file.pdf")
    end

    test "auto-resolves nested path inside volume", %{vol: vol} do
      assert {:ok, path} = FileExplorer.resolve_path("docs/sub/deep/file.md")
      assert path == Path.join(Path.expand(vol), "sub/deep/file.md")
    end

    test "falls back to base_path when first segment is not a known volume" do
      assert {:ok, path} = FileExplorer.resolve_path("unknown/file.txt")
      assert String.ends_with?(path, "file_explorer/unknown/file.txt")
    end

    test "rejects traversal through volume prefix" do
      assert {:error, :path_traversal} = FileExplorer.resolve_path("docs/../../etc/passwd")
    end
  end

  describe "list/1" do
    test "lists files and folders" do
      File.mkdir_p!(Path.join(@test_base, "subdir"))
      File.write!(Path.join(@test_base, "file.txt"), "hello")

      assert {:ok, entries} = FileExplorer.list(".")
      names = Enum.map(entries, & &1.name)

      assert "subdir" in names
      assert "file.txt" in names

      dir = Enum.find(entries, &(&1.name == "subdir"))
      assert dir.type == :directory

      file = Enum.find(entries, &(&1.name == "file.txt"))
      assert file.type == :file
      assert file.size == 5
    end

    test "returns error for non-directory" do
      File.write!(Path.join(@test_base, "file.txt"), "hello")
      assert {:error, :not_a_directory} = FileExplorer.list("file.txt")
    end

    test "returns error for traversal" do
      assert {:error, :path_traversal} = FileExplorer.list("../..")
    end

    test "uses configured file_stats_concurrency when provided" do
      File.mkdir_p!(Path.join(@test_base, "nested"))
      File.write!(Path.join(@test_base, "a.txt"), "a")

      original = Application.get_env(:zaq, Zaq.Ingestion, [])

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original)
      end)

      Application.put_env(:zaq, Zaq.Ingestion, Keyword.put(original, :file_stats_concurrency, 1))

      assert {:ok, entries} = FileExplorer.list(".")
      assert Enum.any?(entries, &(&1.name == "a.txt"))
      assert Enum.any?(entries, &(&1.name == "nested"))
    end

    test "falls back to default file_stats_concurrency when configured value is invalid" do
      File.write!(Path.join(@test_base, "b.txt"), "b")

      original = Application.get_env(:zaq, Zaq.Ingestion, [])

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original)
      end)

      Application.put_env(:zaq, Zaq.Ingestion, Keyword.put(original, :file_stats_concurrency, 0))

      assert {:ok, entries} = FileExplorer.list(".")
      assert Enum.any?(entries, &(&1.name == "b.txt"))
    end
  end

  describe "file_info/1" do
    test "returns metadata for a file" do
      File.write!(Path.join(@test_base, "doc.md"), "# Title")

      assert {:ok, info} = FileExplorer.file_info("doc.md")
      assert info.name == "doc.md"
      assert info.type == :file
      assert info.size == 7
      assert %DateTime{} = info.modified_at
    end

    test "returns metadata for a directory" do
      File.mkdir_p!(Path.join(@test_base, "subdir"))

      assert {:ok, info} = FileExplorer.file_info("subdir")
      assert info.type == :directory
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = FileExplorer.file_info("nope.txt")
    end
  end

  describe "upload/2" do
    test "writes file to base path" do
      assert {:ok, full_path} = FileExplorer.upload("new.txt", "content")
      assert File.read!(full_path) == "content"
    end

    test "creates subdirectories as needed" do
      assert {:ok, full_path} = FileExplorer.upload("sub/deep/file.md", "data")
      assert File.read!(full_path) == "data"
    end

    test "rejects traversal in upload" do
      assert {:error, :path_traversal} = FileExplorer.upload("../../evil.txt", "bad")
    end
  end

  describe "delete/1" do
    test "deletes an existing file" do
      path = Path.join(@test_base, "remove.txt")
      File.write!(path, "content")

      assert :ok = FileExplorer.delete("remove.txt")
      assert not File.exists?(path)
    end

    test "rejects traversal in delete" do
      assert {:error, :path_traversal} = FileExplorer.delete("../../outside.txt")
    end
  end

  describe "delete_directory/1" do
    test "removes a directory recursively" do
      dir = Path.join(@test_base, "to_remove")
      nested = Path.join(dir, "nested")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "doc.md"), "# title")

      assert :ok = FileExplorer.delete_directory("to_remove")
      assert not File.exists?(dir)
    end

    test "returns error when path is not a directory" do
      File.write!(Path.join(@test_base, "single.txt"), "content")
      assert {:error, :not_a_directory} = FileExplorer.delete_directory("single.txt")
    end
  end

  describe "rename/2" do
    test "renames a file inside base path" do
      old_path = Path.join(@test_base, "old.txt")
      new_path = Path.join(@test_base, "new.txt")
      File.write!(old_path, "value")

      assert :ok = FileExplorer.rename("old.txt", "new.txt")
      assert File.read!(new_path) == "value"
      assert not File.exists?(old_path)
    end

    test "rejects traversal in destination" do
      assert {:error, :path_traversal} = FileExplorer.rename("inside.txt", "../../outside.txt")
    end
  end

  describe "create_directory/1" do
    test "creates directories recursively" do
      assert :ok = FileExplorer.create_directory("a/b/c")
      assert File.dir?(Path.join(@test_base, "a/b/c"))
    end

    test "rejects traversal when creating directory" do
      assert {:error, :path_traversal} = FileExplorer.create_directory("../../escape")
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # Volume-aware API tests (multi-volume ingestion)
  # ──────────────────────────────────────────────────────────────────

  describe "list_volumes/0" do
    test "returns 'default' volume derived from base_path when no volumes configured" do
      volumes = FileExplorer.list_volumes()
      assert Map.has_key?(volumes, "default")
      assert volumes["default"] == Path.expand(@test_base)
    end

    test "returns named volumes when volumes map is configured" do
      vol_a = Path.join(@test_base, "vol_a")
      vol_b = Path.join(@test_base, "vol_b")
      File.mkdir_p!(vol_a)
      File.mkdir_p!(vol_b)
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => vol_a, "archives" => vol_b})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      volumes = FileExplorer.list_volumes()
      assert Map.has_key?(volumes, "docs")
      assert Map.has_key?(volumes, "archives")
      refute Map.has_key?(volumes, "default")
    end
  end

  describe "resolve_path/2 (volume-aware)" do
    setup do
      vol = Path.join(@test_base, "vol_resolve")
      File.mkdir_p!(vol)
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => vol})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      %{vol: vol}
    end

    test "resolves a valid path within a named volume", %{vol: vol} do
      assert {:ok, path} = FileExplorer.resolve_path("docs", "subdir/file.txt")
      assert path == Path.join(Path.expand(vol), "subdir/file.txt")
    end

    test "rejects unknown volume name" do
      assert {:error, :unknown_volume} = FileExplorer.resolve_path("nonexistent", "path")
    end

    test "rejects path traversal within volume" do
      assert {:error, :path_traversal} = FileExplorer.resolve_path("docs", "../../etc/passwd")
    end

    test "resolves root '.' within volume", %{vol: vol} do
      assert {:ok, path} = FileExplorer.resolve_path("docs", ".")
      assert path == Path.expand(vol)
    end
  end

  describe "list/2 (volume-aware)" do
    setup do
      vol = Path.join(@test_base, "vol_list")
      File.mkdir_p!(vol)
      File.write!(Path.join(vol, "hello.txt"), "world")
      File.mkdir_p!(Path.join(vol, "subdir"))
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => vol})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      :ok
    end

    test "lists entries in a named volume" do
      assert {:ok, entries} = FileExplorer.list("docs", ".")
      names = Enum.map(entries, & &1.name)
      assert "hello.txt" in names
      assert "subdir" in names
    end

    test "returns error for unknown volume" do
      assert {:error, :unknown_volume} = FileExplorer.list("unknown_vol", ".")
    end

    test "returns error for path traversal" do
      assert {:error, :path_traversal} = FileExplorer.list("docs", "../..")
    end

    test "returns error when path is not a directory" do
      assert {:error, :not_a_directory} = FileExplorer.list("docs", "hello.txt")
    end
  end

  describe "file_info/2 (volume-aware)" do
    setup do
      vol = Path.join(@test_base, "vol_info")
      File.mkdir_p!(vol)
      File.write!(Path.join(vol, "doc.md"), "# Title")
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => vol})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      :ok
    end

    test "returns metadata for a file in the volume" do
      assert {:ok, info} = FileExplorer.file_info("docs", "doc.md")
      assert info.name == "doc.md"
      assert info.type == :file
      assert info.size == 7
    end

    test "returns error for unknown volume" do
      assert {:error, :unknown_volume} = FileExplorer.file_info("unknown_vol", "doc.md")
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = FileExplorer.file_info("docs", "nope.txt")
    end
  end

  describe "upload/3 (volume-aware)" do
    setup do
      vol = Path.join(@test_base, "vol_upload")
      File.mkdir_p!(vol)
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => vol})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      %{vol: vol}
    end

    test "writes file to the named volume", %{vol: vol} do
      assert {:ok, full_path} = FileExplorer.upload("docs", "new.txt", "content")
      assert File.read!(full_path) == "content"
      assert full_path == Path.join(Path.expand(vol), "new.txt")
    end

    test "creates subdirectories as needed" do
      assert {:ok, _} = FileExplorer.upload("docs", "sub/deep/file.md", "data")
    end

    test "rejects unknown volume" do
      assert {:error, :unknown_volume} = FileExplorer.upload("unknown_vol", "file.txt", "data")
    end

    test "rejects path traversal in upload" do
      assert {:error, :path_traversal} = FileExplorer.upload("docs", "../../evil.txt", "bad")
    end
  end

  describe "delete/2 (volume-aware)" do
    setup do
      vol = Path.join(@test_base, "vol_delete")
      File.mkdir_p!(vol)
      File.write!(Path.join(vol, "remove.txt"), "content")
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => vol})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      %{vol: vol}
    end

    test "deletes an existing file in the volume", %{vol: vol} do
      assert :ok = FileExplorer.delete("docs", "remove.txt")
      refute File.exists?(Path.join(vol, "remove.txt"))
    end

    test "rejects unknown volume" do
      assert {:error, :unknown_volume} = FileExplorer.delete("unknown_vol", "file.txt")
    end

    test "rejects path traversal" do
      assert {:error, :path_traversal} = FileExplorer.delete("docs", "../../outside.txt")
    end
  end

  describe "delete_directory/2 (volume-aware)" do
    setup do
      vol = Path.join(@test_base, "vol_deldir")
      dir = Path.join(vol, "to_remove")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "file.md"), "content")
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => vol})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      %{vol: vol, dir: dir}
    end

    test "removes a directory recursively", %{dir: dir} do
      assert :ok = FileExplorer.delete_directory("docs", "to_remove")
      refute File.exists?(dir)
    end

    test "rejects unknown volume" do
      assert {:error, :unknown_volume} =
               FileExplorer.delete_directory("unknown_vol", "to_remove")
    end

    test "returns error when path is not a directory", %{vol: vol} do
      File.write!(Path.join(vol, "file.txt"), "content")
      assert {:error, :not_a_directory} = FileExplorer.delete_directory("docs", "file.txt")
    end
  end

  describe "rename/3 (volume-aware)" do
    setup do
      vol = Path.join(@test_base, "vol_rename")
      File.mkdir_p!(vol)
      File.write!(Path.join(vol, "old.txt"), "value")
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => vol})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      %{vol: vol}
    end

    test "renames a file within the volume", %{vol: vol} do
      assert :ok = FileExplorer.rename("docs", "old.txt", "new.txt")
      assert File.read!(Path.join(vol, "new.txt")) == "value"
      refute File.exists?(Path.join(vol, "old.txt"))
    end

    test "rejects unknown volume" do
      assert {:error, :unknown_volume} =
               FileExplorer.rename("unknown_vol", "a.txt", "b.txt")
    end

    test "rejects traversal in destination" do
      assert {:error, :path_traversal} =
               FileExplorer.rename("docs", "old.txt", "../../outside.txt")
    end
  end

  describe "folder_size/2 (volume-aware)" do
    setup do
      vol = Path.join(@test_base, "vol_size")
      File.mkdir_p!(vol)
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => vol})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      %{vol: vol}
    end

    test "returns total size of files recursively", %{vol: vol} do
      File.write!(Path.join(vol, "a.txt"), "hello")
      nested = Path.join(vol, "nested")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "b.txt"), "world!")

      size = FileExplorer.folder_size("docs", ".")
      assert size == byte_size("hello") + byte_size("world!")
    end

    test "returns 0 for an empty folder", %{vol: _vol} do
      assert FileExplorer.folder_size("docs", "empty_subdir") == 0
    end

    test "returns 0 for unknown volume" do
      assert FileExplorer.folder_size("nonexistent", ".") == 0
    end
  end

  describe "create_directory/2 (volume-aware)" do
    setup do
      vol = Path.join(@test_base, "vol_mkdir")
      File.mkdir_p!(vol)
      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => vol})
      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
      %{vol: vol}
    end

    test "creates directories recursively in the volume", %{vol: vol} do
      assert :ok = FileExplorer.create_directory("docs", "a/b/c")
      assert File.dir?(Path.join(vol, "a/b/c"))
    end

    test "rejects unknown volume" do
      assert {:error, :unknown_volume} =
               FileExplorer.create_directory("unknown_vol", "a/b/c")
    end

    test "rejects traversal" do
      assert {:error, :path_traversal} =
               FileExplorer.create_directory("docs", "../../escape")
    end
  end
end
