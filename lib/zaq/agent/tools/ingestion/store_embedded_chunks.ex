defmodule Zaq.Agent.Tools.Ingestion.StoreEmbeddedChunks do
  @moduledoc """
  Indexes a verified source document using supplied chunks and vectors.

  A current Back Office super admin starts with a new UUID, a fresh source
  `record` with signed permissions, and converted `markdown`. Resume with the
  same `attempt_id` and only the remaining items. Coordinated callers can pass
  an early `reservation_id` for that attempt. Each vector is explicitly labelled
  with its source `chunk_index`.
  """

  alias Jido.Action.Tool
  alias Zaq.Event
  alias Zaq.Ingestion.EmbeddedChunkStorage
  alias Zaq.NodeRouter

  use Zaq.Engine.Workflows.Action,
    name: "store_embedded_chunks",
    description: "Index chunks and their precomputed vectors for a verified source document.",
    schema: EmbeddedChunkStorage.schema(),
    output_schema:
      Zoi.object(%{
        document_id: Zoi.integer(),
        attempt_id: Zoi.string(),
        results:
          Zoi.list(
            Zoi.object(%{
              chunk_index: Zoi.integer(),
              status: Zoi.enum(["stored", "already_stored", "error"]),
              error: Zoi.string() |> Zoi.optional()
            })
          )
      })

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params),
    do: {:ok, Tool.convert_params_using_schema(params, schema())}

  def on_before_validate_params(params), do: {:ok, params}

  @impl Jido.Action
  def run(params, context) do
    event =
      Event.new(params, :ingestion,
        actor: context[:actor],
        opts: [action: :store_embedded_chunks, confidential: true]
      )

    router = context[:node_router] || NodeRouter

    case router.dispatch(event).response do
      {:ok, result} -> {:ok, result}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :chunk_storage_failed}
    end
  end
end
