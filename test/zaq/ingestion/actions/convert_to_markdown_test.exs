defmodule Zaq.Ingestion.Actions.ConvertToMarkdownTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.Actions.ConvertToMarkdown

  setup do
    original = Application.get_env(:zaq, :document_processor)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:zaq, :document_processor),
        else: Application.put_env(:zaq, :document_processor, original)
    end)

    # Use the real DocumentProcessor for these tests — it reads .md files directly.
    Application.delete_env(:zaq, :document_processor)
    :ok
  end

  defp tmp_md_file(content \\ "# Hello\n\nWorld.") do
    path = Path.join(System.tmp_dir!(), "convert_test_#{System.unique_integer([:positive])}.md")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "run/2" do
    test "returns content map on success for a plain .md file" do
      path = tmp_md_file()

      assert {:ok, result} = ConvertToMarkdown.run(%{file_path: path}, %{})
      assert result.file_path == path
      assert is_binary(result.md_content)
      assert is_binary(result.md_path)
      assert is_boolean(result.converted)
    end

    test "converted: true for plain .md (no sidecar — file is already markdown)" do
      path = tmp_md_file()
      # md_path == file_path: sidecar_existed = (md_path != file_path) and exists? = false
      # so converted = not false = true
      assert {:ok, %{converted: true}} = ConvertToMarkdown.run(%{file_path: path}, %{})
    end

    test "md_content matches file content for plain .md" do
      path = tmp_md_file("# Title\n\nBody text.")
      assert {:ok, %{md_content: content}} = ConvertToMarkdown.run(%{file_path: path}, %{})
      assert content =~ "Title"
    end

    test "returns {:error, _} when file does not exist" do
      path = "/nonexistent/path/to/file.md"
      assert {:error, _reason} = ConvertToMarkdown.run(%{file_path: path}, %{})
    end
  end
end
