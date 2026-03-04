defmodule Zaq.Ingestion.FileExplorerTest do
  use ExUnit.Case, async: true

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
end
