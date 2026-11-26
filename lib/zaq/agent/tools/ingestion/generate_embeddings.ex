defmodule Zaq.Agent.Tools.Ingestion.GenerateEmbeddings do
  @moduledoc """
  Generates vectors with the configured embedding provider without indexing.

  Supply `texts` as a list of 1 to 16 strings, each at most 64 KiB. Use a
  one-item list for a single text and `ChunkContent`'s `embedding_input` when
  embedding chunks. Results follow input order, including failures and
  unattempted items.
  """

  alias Jido.Action.Tool
  alias Zaq.Embedding.Client

  @max_texts 16
  @max_text_bytes 65_536

  use Zaq.Engine.Workflows.Action,
    name: "generate_embeddings",
    description: "Generate vectors for an ordered list of texts without indexing.",
    schema:
      Zoi.object(
        %{texts: Zoi.list(Zoi.string()) |> Zoi.min(1) |> Zoi.max(@max_texts)},
        unrecognized_keys: :error
      ),
    output_schema:
      Zoi.object(%{
        results:
          Zoi.list(
            Zoi.object(%{
              index: Zoi.integer() |> Zoi.positive(),
              status: Zoi.enum(["ok", "error", "not_attempted"]),
              vector: Zoi.list(Zoi.number()) |> Zoi.optional(),
              dimension: Zoi.integer() |> Zoi.positive() |> Zoi.optional(),
              model: Zoi.string() |> Zoi.optional(),
              error: Zoi.string() |> Zoi.optional(),
              http_status: Zoi.integer() |> Zoi.optional(),
              retry_after_seconds: Zoi.integer() |> Zoi.min(0) |> Zoi.optional()
            })
          )
      })

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params),
    do: {:ok, Tool.convert_params_using_schema(params, schema())}

  def on_before_validate_params(params), do: {:ok, params}

  @impl Jido.Action
  def run(%{texts: texts}, _context) do
    if Enum.all?(texts, &valid_text?/1) do
      {:ok, %{results: Client.embed_batch(texts)}}
    else
      {:error, :invalid_embedding_text}
    end
  end

  defp valid_text?(text) do
    byte_size(text) <= @max_text_bytes and String.valid?(text) and String.trim(text) != ""
  end
end
