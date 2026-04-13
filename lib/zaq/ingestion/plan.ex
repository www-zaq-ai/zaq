defmodule Zaq.Ingestion.Plan do
  @moduledoc """
  Defines the ingestion pipeline as a `Jido.Plan` DAG.

  The full pipeline is a strictly sequential chain of five actions:

      UploadFile → ConvertToMarkdown → ChunkDocument → EmbedChunks → AddToRag

  Three execution modes are supported, each backed by a tailored action list
  for use with `Jido.Exec.Chain.chain/3`:

  | Mode              | Actions                                              | Entry status → Exit status  |
  |-------------------|------------------------------------------------------|------------------------------|
  | `:full`           | all five                                              | `processing` → `completed`  |
  | `:upload_only`    | `UploadFile`, `ConvertToMarkdown`, `RegisterSidecar` | `processing` → `converted`  |
  | `:from_converted` | `ChunkDocument`, `EmbedChunks`, `AddToRag`           | `processing` → `completed`  |

  `Zaq.Ingestion.Agent` selects the mode automatically based on whether a `.md`
  sidecar already exists on disk, then calls `chain/0` to get the action list.
  """

  alias Jido.Plan

  alias Zaq.Ingestion.Actions.{
    AddToRag,
    ChunkDocument,
    ConvertToMarkdown,
    EmbedChunks,
    RegisterSidecar,
    UploadFile
  }

  @doc """
  Builds the full `Jido.Plan` DAG for the ingestion pipeline.

  Useful for visualisation, static analysis, and generating dependency graphs.
  Execution itself goes through `Jido.Exec.Chain` via `chain/1`.
  """
  @spec build() :: Plan.t()
  def build do
    Plan.new()
    |> Plan.add(:upload, UploadFile)
    |> Plan.add(:convert, ConvertToMarkdown, depends_on: :upload)
    |> Plan.add(:chunk, ChunkDocument, depends_on: :convert)
    |> Plan.add(:embed, EmbedChunks, depends_on: :chunk)
    |> Plan.add(:rag, AddToRag, depends_on: :embed)
  end

  @doc """
  Returns the ordered action list for `mode`.

  Used with `Jido.Exec.Chain.chain/3`.
  """
  @spec chain(:full | :upload_only | :from_converted) :: [module()]
  def chain(:full), do: [UploadFile, ConvertToMarkdown, ChunkDocument, EmbedChunks, AddToRag]
  def chain(:upload_only), do: [UploadFile, ConvertToMarkdown, RegisterSidecar]
  def chain(:from_converted), do: [ChunkDocument, EmbedChunks, AddToRag]
end
