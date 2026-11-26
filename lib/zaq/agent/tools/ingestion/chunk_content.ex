defmodule Zaq.Agent.Tools.Ingestion.ChunkContent do
  @moduledoc """
  Splits supplied Markdown or plain text using ingestion's layout-aware chunker.

  Returns ordered chunks without reading files, embedding text or indexing a
  document. Pass each chunk's `embedding_input` to the embedding model and keep
  `content` for display and indexing. Empty or non-searchable content yields
  an empty list.
  """

  alias Jido.Action.Tool
  alias Zaq.Ingestion.{DocumentChunker, DocumentProcessor}

  @max_content_bytes 5 * 1024 * 1024

  use Zaq.Engine.Workflows.Action,
    name: "chunk_content",
    description: "Split Markdown or plain text into searchable chunks without indexing it.",
    schema:
      Zoi.object(%{
        content: Zoi.string(description: "UTF-8 content, at most 5 MiB"),
        format: Zoi.enum(["markdown", "text"]) |> Zoi.default("markdown")
      }),
    output_schema:
      Zoi.object(%{
        chunks:
          Zoi.list(
            Zoi.object(%{
              chunk_index: Zoi.integer() |> Zoi.positive(),
              content: Zoi.string(),
              tokens: Zoi.integer(),
              section_path: Zoi.list(Zoi.string()),
              metadata: Zoi.map(),
              embedding_input: Zoi.string()
            })
          )
      })

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params),
    do: {:ok, Tool.convert_params_using_schema(params, schema())}

  def on_before_validate_params(params), do: {:ok, params}

  @impl Jido.Action
  def run(%{content: content, format: format}, _context) do
    cond do
      byte_size(content) > @max_content_bytes -> {:error, :content_too_large}
      not String.valid?(content) -> {:error, :invalid_content}
      true -> {:ok, %{chunks: split(content, format)}}
    end
  end

  defp split(content, format) do
    layout = if format == "text", do: :text, else: :markdown

    content
    |> DocumentChunker.parse_layout(format: layout)
    |> DocumentChunker.chunk_sections()
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} ->
      %{
        chunk_index: index,
        content: chunk.content,
        tokens: chunk.tokens,
        section_path: chunk.section_path,
        metadata: DocumentProcessor.build_metadata(chunk),
        embedding_input: chunk.embedding_input
      }
    end)
  end
end
