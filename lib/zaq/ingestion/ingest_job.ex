defmodule Zaq.Ingestion.IngestJob do
  @moduledoc """
  Ecto schema for tracking document ingestion jobs.
  Each job represents the processing of a single document file, with fields to track status, errors, and results.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending processing completed completed_with_errors failed)
  @modes ~w(inline async)

  schema "ingest_jobs" do
    field :file_path, :string
    field :status, :string, default: "pending"
    field :error, :string
    field :mode, :string, default: "async"
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :chunks_count, :integer, default: 0
    field :total_chunks, :integer, default: 0
    field :ingested_chunks, :integer, default: 0
    field :failed_chunks, :integer, default: 0
    field :failed_chunk_indices, {:array, :integer}, default: []
    field :document_id, :integer
    field :volume_name, :string
    field :role_id, :integer
    field :shared_role_ids, {:array, :integer}, default: []

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def modes, do: @modes

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :file_path,
      :status,
      :error,
      :mode,
      :started_at,
      :completed_at,
      :chunks_count,
      :total_chunks,
      :ingested_chunks,
      :failed_chunks,
      :failed_chunk_indices,
      :document_id,
      :volume_name,
      :role_id,
      :shared_role_ids
    ])
    |> validate_required([:file_path, :status, :mode])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:mode, @modes)
  end
end
