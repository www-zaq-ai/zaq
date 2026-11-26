defmodule Zaq.Agent.Tools.Ingestion.GenerateEmbeddings do
  @moduledoc """
  Generates vectors with the configured embedding provider without indexing.

  Supply either `text` or up to 16 ordered `texts`, each at most 64 KiB.
  Use `ChunkContent`'s `embedding_input` when embedding chunks. Both input forms
  return one result per input, in order, including failures and unattempted items.
  """

  alias Jido.Action.Tool
  alias Zaq.Embedding.Client

  @max_texts 16
  @max_text_bytes 65_536

  use Zaq.Engine.Workflows.Action,
    name: "generate_embeddings",
    description:
      "Generate vectors for supplied text without indexing. Set text or texts, not both.",
    schema:
      Zoi.object(%{
        text: Zoi.string() |> Zoi.optional(),
        texts: Zoi.list(Zoi.string()) |> Zoi.min(1) |> Zoi.max(@max_texts) |> Zoi.optional()
      }),
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
  def run(params, _context) do
    with {:ok, texts} <- requested_texts(params[:text], params[:texts]),
         true <- Enum.all?(texts, &valid_text?/1) do
      {:ok, %{results: Client.embed_batch(texts)}}
    else
      false -> {:error, :invalid_embedding_text}
      {:error, _reason} = error -> error
    end
  end

  defp requested_texts(text, nil) when is_binary(text), do: {:ok, [text]}
  defp requested_texts(nil, texts) when is_list(texts), do: {:ok, texts}
  defp requested_texts(_text, _texts), do: {:error, :choose_text_or_texts}

  defp valid_text?(text) do
    byte_size(text) <= @max_text_bytes and String.valid?(text) and String.trim(text) != ""
  end
end
