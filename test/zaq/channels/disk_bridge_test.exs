defmodule Zaq.Channels.DiskBridgeTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.DiskBridge
  alias Zaq.Ingestion.FileExplorer

  @test_base "test/tmp/disk_bridge"

  # 60x60 red circle on white, 275 bytes. Small enough to inline, real enough
  # that a corrupt write fails the byte comparison rather than passing on a
  # placeholder.
  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAADwAAAA8CAIAAAC1nk4lAAAA2klEQVR4nO3auRHDMAwEQFWj/gtyL3bqsSR8" <>
                "xGfwbpBjmfJwvP8wRzXAEqCz4ol+nScxjotW0TQ06AF2tI3rQreg17mLdB3al2umK9BxYq1bio4Wq9wi" <>
                "dI5Y7ubRmWKhm0HniyVuCl0lZt2P6Fox7R6ELufS7inocijrHoEuJ0rcQAMtRZfjhG6ggQYaaKD7zSx0" <>
                "W/cPEmigFeiG7qtwCrqV+5Y3CN3E/WSbhS53E7Bxn+pVbpY0tCjKdAsxo8vPaLeKsUGh70s3r97sSOWa" <>
                "UOh3tj+8SgvQWfkAgfLMx/F4LS0AAAAASUVORK5CYII="
  @png_bytes Base.decode64!(@png_base64)

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
        filename: "report.md",
        content: "# Report\ncontent",
        mime_type: "text/markdown"
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

  describe "create_file/2 with a binary mime type" do
    test "decodes Base64 content and writes the raw bytes" do
      params = %{
        "name" => "red-circle",
        "content" => @png_base64,
        "mime_type" => "image/png"
      }

      assert {:ok, %{status: "created", record: record}} = DiskBridge.create_file(%{}, params)

      assert record.name == "red-circle.png"
      assert record.path == "generated/red-circle.png"
      assert record.mime_type == "image/png"
      assert record.size == byte_size(@png_bytes)

      assert {:ok, abs_path} = FileExplorer.resolve_path("generated/red-circle.png")
      assert File.read!(abs_path) == @png_bytes
    end

    test "strips whitespace before decoding so wrapped Base64 survives" do
      wrapped = @png_base64 |> String.codepoints() |> Enum.chunk_every(76) |> Enum.join("\n")

      params = %{"name" => "wrapped", "content" => wrapped, "mime_type" => "image/png"}

      assert {:ok, %{record: _record}} = DiskBridge.create_file(%{}, params)

      assert {:ok, abs_path} = FileExplorer.resolve_path("generated/wrapped.png")
      assert File.read!(abs_path) == @png_bytes
    end

    test "maps common binary mime types to their own extension" do
      for {mime, ext} <- [
            {"image/png", ".png"},
            {"image/jpeg", ".jpg"},
            {"image/gif", ".gif"},
            {"image/webp", ".webp"},
            {"application/pdf", ".pdf"},
            {"application/zip", ".zip"}
          ] do
        params = %{"name" => "asset", "content" => @png_base64, "mime_type" => mime}

        assert {:ok, %{record: record}} = DiskBridge.create_file(%{}, params)
        assert record.name == "asset" <> ext, "expected #{mime} to produce #{ext}"
        assert record.mime_type == mime
      end
    end

    test "keeps an extension already present on the name" do
      params = %{"name" => "red-circle.png", "content" => @png_base64, "mime_type" => "image/png"}

      assert {:ok, %{record: record}} = DiskBridge.create_file(%{}, params)

      assert record.name == "red-circle.png"
      refute record.name =~ ".png.png"
    end

    test "returns invalid_base64 when binary content is not decodable" do
      params = %{"name" => "broken", "content" => "not base64 !!!", "mime_type" => "image/png"}

      assert {:error, :invalid_base64} = DiskBridge.create_file(%{}, params)
    end

    test "writes already-decoded bytes verbatim when content_encoding is raw" do
      params = %{
        "name" => "generated",
        "content" => @png_bytes,
        "mime_type" => "image/png",
        "content_encoding" => "raw"
      }

      assert {:ok, %{record: record}} = DiskBridge.create_file(%{}, params)

      assert record.name == "generated.png"
      assert record.size == byte_size(@png_bytes)

      assert {:ok, abs_path} = FileExplorer.resolve_path("generated/generated.png")
      assert File.read!(abs_path) == @png_bytes
    end

    test "rejects raw bytes that are not declared as raw" do
      # Raw PNG bytes are not valid Base64, so the default binary path refuses
      # them rather than writing something corrupt. A caller holding decoded
      # bytes has to say so.
      params = %{"name" => "oops", "content" => @png_bytes, "mime_type" => "image/png"}

      assert {:error, :invalid_base64} = DiskBridge.create_file(%{}, params)
    end

    test "decodes when content_encoding is explicitly base64" do
      params = %{
        "name" => "explicit",
        "content" => @png_base64,
        "mime_type" => "image/png",
        "content_encoding" => "base64"
      }

      assert {:ok, %{record: record}} = DiskBridge.create_file(%{}, params)

      assert {:ok, abs_path} = FileExplorer.resolve_path("generated/explicit.png")
      assert File.read!(abs_path) == @png_bytes
      assert record.size == byte_size(@png_bytes)
    end

    test "raw content_encoding also bypasses decoding for text mime types" do
      params = %{
        "name" => "verbatim",
        "content" => "aGVsbG8=",
        "mime_type" => "text/plain",
        "content_encoding" => "raw"
      }

      assert {:ok, _} = DiskBridge.create_file(%{}, params)

      assert {:ok, abs_path} = FileExplorer.resolve_path("generated/verbatim.txt")
      assert File.read!(abs_path) == "aGVsbG8="
    end

    test "rejects an unknown content_encoding rather than guessing" do
      params = %{
        "name" => "bad",
        "content" => @png_base64,
        "mime_type" => "image/png",
        "content_encoding" => "hex"
      }

      assert {:error, {:invalid_content_encoding, "hex"}} = DiskBridge.create_file(%{}, params)
    end

    test "does not decode text content that happens to look like Base64" do
      params = %{"name" => "literal", "content" => "aGVsbG8=", "mime_type" => "text/plain"}

      assert {:ok, %{record: record}} = DiskBridge.create_file(%{}, params)

      assert {:ok, abs_path} = FileExplorer.resolve_path("generated/literal.txt")
      assert File.read!(abs_path) == "aGVsbG8="
      assert record.size == byte_size("aGVsbG8=")
    end
  end
end
