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

  describe "create_file/1" do
    test "creates a file from base64 content and returns metadata" do
      content = Base.encode64("# Report\ncontent")
      params = %{filename: "report.pdf", content: content, mime_type: "application/pdf"}

      assert {:ok, result} = DiskBridge.create_file(params)

      assert result.name == "report.md"
      assert result.path == "generated/report.md"
      assert result.mime_type == "text/markdown"
      assert result.url == "/bo/files/generated/report.md"

      assert {:ok, abs_path} = FileExplorer.resolve_path("generated/report.md")
      assert File.exists?(abs_path)
      assert File.read!(abs_path) == "# Report\ncontent"
    end

    test "creates file in custom path when provided and resolvable" do
      content = Base.encode64("hello")

      params = %{
        filename: "notes.txt",
        content: content,
        path: "archives",
        mime_type: "text/plain"
      }

      assert {:ok, result} = DiskBridge.create_file(params)

      assert result.name == "notes.md"
      assert result.path == "archives/notes.md"
      assert result.url == "/bo/files/archives/notes.md"
    end

    test "falls back to generated/ when path does not resolve" do
      content = Base.encode64("data")
      params = %{filename: "test.txt", content: content, path: "../nonexistent"}

      assert {:ok, result} = DiskBridge.create_file(params)

      assert result.path == "generated/test.md"
    end

    test "handles filename without extension" do
      content = Base.encode64("# Readme")
      params = %{filename: "README", content: content}

      assert {:ok, result} = DiskBridge.create_file(params)

      assert result.name == "README.md"
      assert result.path == "generated/README.md"
    end

    test "falls back to generated/ when path is a traversal attempt" do
      content = Base.encode64("bad")
      params = %{filename: "evil.txt", content: content, path: ".."}

      assert {:ok, result} = DiskBridge.create_file(params)

      assert result.path == "generated/evil.md"
    end

    test "returns error for invalid base64 content" do
      params = %{filename: "test.txt", content: "not-valid-base64!!!"}

      assert {:error, :invalid_base64} = DiskBridge.create_file(params)
    end
  end
end
