defmodule Zaq.Ingestion.IngestChunkJob do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending processing completed failed_final)

  schema "ingest_chunk_jobs" do
    field :document_id, :integer
    field :chunk_index, :integer
    field :chunk_payload, :map
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :error, :string

    belongs_to :ingest_job, Zaq.Ingestion.IngestJob

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(chunk_job, attrs) do
    chunk_job
    |> cast(attrs, [
      :ingest_job_id,
      :document_id,
      :chunk_index,
      :chunk_payload,
      :status,
      :attempts,
      :error
    ])
    |> validate_required([:ingest_job_id, :document_id, :chunk_index, :chunk_payload, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:ingest_job_id, :chunk_index])
  end

  def upsert_many(ingest_job_id, document_id, indexed_chunks) do
    now = DateTime.utc_now()

    rows =
      Enum.map(indexed_chunks, fn {chunk_payload, chunk_index} ->
        %{
          ingest_job_id: ingest_job_id,
          document_id: document_id,
          chunk_index: chunk_index,
          chunk_payload: chunk_payload,
          status: "pending",
          attempts: 0,
          error: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(
      __MODULE__,
      rows,
      on_conflict: {:replace, [:chunk_payload, :status, :attempts, :error, :updated_at]},
      conflict_target: [:ingest_job_id, :chunk_index]
    )
  end

  def list_failed_final(ingest_job_id) do
    from(c in __MODULE__,
      where: c.ingest_job_id == ^ingest_job_id and c.status == "failed_final",
      order_by: [asc: c.chunk_index]
    )
    |> Repo.all()
  end

  def count_completed(ingest_job_id) do
    from(c in __MODULE__,
      where: c.ingest_job_id == ^ingest_job_id and c.status == "completed",
      select: count(c.id)
    )
    |> Repo.one()
  end

  def count_failed_final(ingest_job_id) do
    from(c in __MODULE__,
      where: c.ingest_job_id == ^ingest_job_id and c.status == "failed_final",
      select: count(c.id)
    )
    |> Repo.one()
  end

  def count_terminal(ingest_job_id) do
    from(c in __MODULE__,
      where: c.ingest_job_id == ^ingest_job_id and c.status in ["completed", "failed_final"],
      select: count(c.id)
    )
    |> Repo.one()
  end

  def count_all(ingest_job_id) do
    from(c in __MODULE__, where: c.ingest_job_id == ^ingest_job_id, select: count(c.id))
    |> Repo.one()
  end

  def requeue_failed_final(ingest_job_id) do
    from(c in __MODULE__, where: c.ingest_job_id == ^ingest_job_id and c.status == "failed_final")
    |> Repo.update_all(
      set: [status: "pending", attempts: 0, error: nil, updated_at: DateTime.utc_now()]
    )
  end
end
