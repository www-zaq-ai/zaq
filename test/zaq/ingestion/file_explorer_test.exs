defmodule Zaq.Ingestion.FileExplorerTest do
  use ExUnit.Case, async: false

  alias Zaq.Ingestion.FileExplorer

  @test_base "test/tmp/file_explorer"

  setup do
    # Create a fresh temp directory for each test
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
end
