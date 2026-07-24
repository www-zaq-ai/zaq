defmodule Zaq.Agent.Tools.Files.CreateFileTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Files.CreateFile

  @ctx %{}

  describe "run/2" do
    test "returns staged metadata with raw data" do
      assert {:ok, result} =
               CreateFile.run(
                 %{
                   filename: "report.pdf",
                   data: "# Report\ncontent",
                   mime_type: "application/pdf"
                 },
                 @ctx
               )

      assert result.name == "report.md"
      assert result.path == "generated/report.md"
      assert result.mime_type == "text/markdown"
      assert result.url == "/bo/files/generated/report.md"
      assert result.size == 16
      assert result.data == "# Report\ncontent"
    end

    test "includes directory in path when provided" do
      assert {:ok, result} =
               CreateFile.run(
                 %{
                   filename: "notes.txt",
                   data: "hello",
                   mime_type: "text/plain",
                   path: "archives"
                 },
                 @ctx
               )

      assert result.path == "archives/notes.md"
      assert result.url == "/bo/files/archives/notes.md"
    end

    test "handles filename without extension" do
      assert {:ok, result} =
               CreateFile.run(
                 %{filename: "README", data: "# Readme", mime_type: "text/markdown"},
                 @ctx
               )

      assert result.name == "README.md"
      assert result.path == "generated/README.md"
    end
  end
end
