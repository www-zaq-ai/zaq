defmodule Zaq.Ingestion.Chunk do
  @moduledoc """
  Ecto schema for document chunks with vector embeddings.

  Each chunk belongs to a `Zaq.Ingestion.Document` and stores:
  - The chunk text content
  - Its position within the document
  - Section path for hierarchical navigation
  - Metadata (section type, level, token count, etc.)
  - A vector embedding for similarity search

  Replaces the legacy raw SQL `zaq_knowledge` table from zaq_agent.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Ingestion.Document
  alias Zaq.Repo

  schema "chunks" do
    belongs_to :document, Document
    field :content, :string
    field :chunk_index, :integer
    field :section_path, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :embedding, Pgvector.Ecto.HalfVector

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(document_id content chunk_index)a
  @optional_fields ~w(section_path metadata embedding)a

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:document_id)
  end

  @doc """
  Sets the embedding on a chunk changeset.
  Kept separate from changeset/2 since embeddings are generated
  asynchronously and are not part of user-provided attrs.
  """
  def put_embedding(changeset, embedding) when is_list(embedding) do
    put_change(changeset, :embedding, Pgvector.HalfVector.new(embedding))
  end

  # -- Query API --

  @doc """
  Inserts a new chunk.
  """
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Inserts a chunk with its embedding in a single call.
  """
  def create_with_embedding(attrs, embedding) when is_list(embedding) do
    %__MODULE__{}
    |> changeset(attrs)
    |> put_embedding(embedding)
    |> Repo.insert()
  end

  @doc """
  Returns all chunks for a given document, ordered by chunk_index.
  """
  def list_by_document(document_id) do
    from(c in __MODULE__,
      where: c.document_id == ^document_id,
      order_by: [asc: c.chunk_index]
    )
    |> Repo.all()
  end

  @doc """
  Deletes all chunks for a given document.
  Used before re-ingesting a document.
  """
  def delete_by_document(document_id) do
    from(c in __MODULE__, where: c.document_id == ^document_id)
    |> Repo.delete_all()
  end

  @doc """
  Returns the count of chunks for a given document.
  """
  def count_by_document(document_id) do
    from(c in __MODULE__,
      where: c.document_id == ^document_id,
      select: count(c.id)
    )
    |> Repo.one()
  end
end
