defmodule Zaq.Agent.Tools.Ingestion.ChunkContentTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Agent.Tools.Ingestion.ChunkContent
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.DocumentChunker.Chunk
  alias Zaq.Ingestion.IngestJob

  test "returns verbatim searchable text and source locators without indexing" do
    markdown = """
    <!-- page: 3 -->
    # Région
    Un café.
    <!-- page: 4 -->
    Une forêt.
    """

    assert {:ok, %{chunks: [chunk]} = output} =
             execute(%{"content" => markdown, "format" => "markdown"})

    assert chunk.chunk_index == 1
    assert chunk.section_path == ["Région"]
    assert chunk.content =~ "Un café."
    assert chunk.content =~ "Une forêt."
    refute chunk.content =~ "<!--"
    assert chunk.embedding_input == "Région\n\n" <> chunk.content
    assert chunk.metadata.start == "P3|L2"
    assert chunk.metadata.end == "P4|L5"
    assert chunk.tokens > 0
    assert {:ok, _} = ChunkContent.validate_output(output)
    assert %{"chunks" => [%{"chunk_index" => 1}]} = output |> Jason.encode!() |> Jason.decode!()
    refute Repo.exists?(Document)
    refute Repo.exists?(IngestJob)
  end

  test "returns a successful empty list for whitespace or an unusable image marker" do
    for content <- [" \n\t", "<!-- page: 2 -->\n![](source.pdf-page-2.png)"] do
      assert {:ok, %{chunks: []}} = execute(%{content: content})
    end
  end

  test "supports plain text without treating its headings as Markdown" do
    assert {:ok, %{chunks: [chunk]}} = execute(%{content: "# Note\nCafé", format: "text"})
    assert chunk.section_path == []
    assert chunk.content == "# Note\nCafé"
    assert chunk.embedding_input == chunk.content
  end

  test "keeps the repeated header on every part of a split table" do
    header = "| Item | Count |"
    rows = Enum.map_join(1..100, "\n", &"| Ligne #{&1} #{String.duplicate("café ", 15)}| #{&1} |")

    assert {:ok, %{chunks: [_, _ | _] = chunks}} =
             execute(%{content: "#{header}\n| --- | --- |\n#{rows}"})

    assert Enum.all?(chunks, &String.starts_with?(&1.content, header))
  end

  test "rejects unsupported formats and oversized text" do
    assert {:error, _} = execute(%{content: "text", format: "html"})
    assert {:error, _} = execute(%{content: :not_text})
    assert {:error, _} = execute(%{content: String.duplicate("é", 2_621_441)})
  end

  property "ordered indices, source text and derived embedding input are stable" do
    check all(
            sentences <-
              list_of(member_of(["Un café.", "森に行く。", "Crème brûlée."]),
                min_length: 1,
                max_length: 6
              )
          ) do
      markdown =
        sentences
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {sentence, index} -> "# Partie #{index}\n\n#{sentence}" end)

      assert {:ok, %{chunks: chunks}} = execute(%{content: markdown})
      assert {:ok, %{chunks: repeated}} = execute(%{content: markdown})

      assert Enum.map(chunks, & &1.chunk_index) == Enum.to_list(1..length(sentences))
      assert Enum.map(chunks, & &1.embedding_input) == Enum.map(repeated, & &1.embedding_input)

      for {chunk, sentence} <- Enum.zip(chunks, sentences) do
        assert chunk.content =~ sentence
        assert chunk.embedding_input == Chunk.embedding_input(chunk.content, chunk.section_path)
        refute chunk.content == chunk.embedding_input
      end
    end
  end

  defp execute(params), do: Jido.Exec.run(ChunkContent, params, %{})
end
