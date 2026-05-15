defmodule Zaq.Ingestion.DeleteServiceTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.{DeleteService, Document}

  @test_base "test/tmp/delete_service"

  setup do
    File.rm_rf!(@test_base)
    File.mkdir_p!(@test_base)
    original = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, original || [])
      File.rm_rf!(@test_base)
    end)

    :ok
  end

  describe "delete_path/3 (3-arg default)" do
    # Covers line 9 — the default-arg function head (volumes \\ nil)
    test "deletes a file using 3-argument call" do
      File.write!(Path.join(@test_base, "file.txt"), "content")
      {:ok, doc} = Document.create(%{source: "file.txt", content: "content"})

      assert :ok = DeleteService.delete_path("default", "file.txt", "file")
      assert Document.get_by_source("file.txt") == nil
    end
  end

  describe "delete_path for directories" do
    # Line 98 — FileExplorer.list returns {:error, :not_a_directory} for any non-directory path
    # (covers non-existent paths AND regular files passed as type "directory")
    test "returns error when a regular file path is given with type directory" do
      File.write!(Path.join(@test_base, "notadir.txt"), "data")

      assert {:error, :not_a_directory} =
               DeleteService.delete_path("default", "notadir.txt", "directory")
    end

    test "returns error when a non-existent path is given with type directory" do
      assert {:error, :not_a_directory} =
               DeleteService.delete_path("default", "totally_missing", "directory")
    end

    # Line 139 — child_path(".", name) when deleting the root "." directory
    test "deletes root-level entries via child_path dot variant" do
      File.write!(Path.join(@test_base, "root_file.txt"), "hello")
      {:ok, _doc} = Document.create(%{source: "root_file.txt", content: "hello"})

      assert :ok = DeleteService.delete_path("default", ".", "directory")
      assert Document.get_by_source("root_file.txt") == nil
    end

    # Line 139 — child_path(".", name) with a nested subdirectory
    test "deletes root-level subdirectory via child_path dot variant" do
      File.mkdir_p!(Path.join(@test_base, "subdir"))
      File.write!(Path.join(@test_base, "subdir/nested.md"), "nested")
      {:ok, _doc} = Document.create(%{source: "subdir/nested.md", content: "nested"})

      assert :ok = DeleteService.delete_path("default", ".", "directory")
      assert Document.get_by_source("subdir/nested.md") == nil
    end
  end

  describe "delete_paths/2" do
    # Covers the 3-arg branch (line 9) and {:error, :not_found} branch
    test "returns not_found for entries that do not exist" do
      results = DeleteService.delete_paths("default", ["ghost.txt"])
      assert [{"ghost.txt", {:error, :not_found}}] = results
    end

    test "deletes file and directory entries in a single call" do
      File.mkdir_p!(Path.join(@test_base, "folder"))
      File.write!(Path.join(@test_base, "file.txt"), "data")
      {:ok, _doc} = Document.create(%{source: "file.txt", content: "data"})

      results = DeleteService.delete_paths("default", ["file.txt", "folder"])

      assert Enum.all?(results, fn {_path, result} -> result == :ok end)
      assert Document.get_by_source("file.txt") == nil
    end

    test "mixes ok, not_found results correctly" do
      File.write!(Path.join(@test_base, "exists.txt"), "data")

      results = DeleteService.delete_paths("default", ["exists.txt", "missing.txt"])

      assert {"exists.txt", :ok} in results
      assert {"missing.txt", {:error, :not_found}} in results
    end
  end
end
