defmodule Zaq.Channels.DiskBridgeTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.DiskBridge
  alias Zaq.Ingestion.FileExplorer

  @test_base "test/tmp/disk_bridge"

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

  describe "create_file/2" do
    test "creates a file and returns the datasource record shape" do
      params = %{
        filename: "report.pdf",
        content: "# Report\ncontent",
        mime_type: "application/pdf"
      }

      assert {:ok, %{status: "created", record: record}} = DiskBridge.create_file(%{}, params)

      assert record.name == "report.md"
      assert record.path == "generated/report.md"
      assert record.id == "generated/report.md"
      assert record.mime_type == "text/markdown"
      assert record.size == byte_size("# Report\ncontent")

      assert {:ok, abs_path} = FileExplorer.resolve_path("generated/report.md")
      assert File.read!(abs_path) == "# Report\ncontent"
    end

    test "accepts string-keyed params from datasource agent tools" do
      params = %{
        "name" => "Report",
        "content" => "body",
        "path" => "archives",
        "mime_type" => "text/plain",
        "parent_id" => "ignored",
        "config_id" => "ignored"
      }

      assert {:ok, %{status: "created", record: record}} = DiskBridge.create_file(%{}, params)

      assert record.name == "Report.txt"
      assert record.path == "archives/Report.txt"
      assert record.mime_type == "text/plain"

      assert {:ok, abs_path} = FileExplorer.resolve_path("archives/Report.txt")
      assert File.read!(abs_path) == "body"
    end

    test "creates file in custom path when provided and resolvable" do
      params = %{
        filename: "notes.txt",
        content: "hello",
        path: "archives",
        mime_type: "text/plain"
      }

      assert {:ok, %{record: record}} = DiskBridge.create_file(%{}, params)

      assert record.name == "notes.txt"
      assert record.path == "archives/notes.txt"
    end

    test "falls back to generated/ when path does not resolve" do
      params = %{filename: "test.txt", content: "data", path: "../nonexistent"}

      assert {:ok, %{record: record}} = DiskBridge.create_file(%{}, params)

      assert record.path == "generated/test.md"
    end

    test "falls back to generated/ when path is a traversal attempt" do
      params = %{filename: "evil.txt", content: "bad", path: ".."}

      assert {:ok, %{record: record}} = DiskBridge.create_file(%{}, params)

      assert record.path == "generated/evil.md"
    end

    test "handles filename without extension" do
      params = %{filename: "README", content: "# Readme"}

      assert {:ok, %{record: record}} = DiskBridge.create_file(%{}, params)

      assert record.name == "README.md"
      assert record.path == "generated/README.md"
    end

    test "falls back to filename when name is absent" do
      assert {:ok, %{record: record}} =
               DiskBridge.create_file(%{}, %{"filename" => "legacy.txt", "content" => "x"})

      assert record.name == "legacy.md"
    end

    test "creates an empty document when content is omitted" do
      assert {:ok, %{record: record}} = DiskBridge.create_file(%{}, %{"name" => "empty"})

      assert record.size == 0

      assert {:ok, abs_path} = FileExplorer.resolve_path("generated/empty.md")
      assert File.read!(abs_path) == ""
    end

    test "returns missing_name when no usable name is provided" do
      assert {:error, :missing_name} = DiskBridge.create_file(%{}, %{"content" => "x"})
      assert {:error, :missing_name} = DiskBridge.create_file(%{}, %{"name" => "   "})
    end

    test "returns invalid_content for non-binary content" do
      assert {:error, :invalid_content} =
               DiskBridge.create_file(%{}, %{"name" => "n", "content" => %{"a" => 1}})
    end
  end
end
