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

      assert result.path == "archives/notes.txt"
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

    test "returns error when required fields are missing" do
      assert {:error, :missing_required_fields} =
               CreateFile.run(%{data: "hello", mime_type: "text/plain"}, @ctx)

      assert {:error, :missing_required_fields} =
               CreateFile.run(%{filename: "test.txt", mime_type: "text/plain"}, @ctx)

      assert {:error, :missing_required_fields} =
               CreateFile.run(%{filename: "test.txt", data: "hello"}, @ctx)
    end
  end
end
