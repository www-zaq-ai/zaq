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

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias Zaq.Hooks
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.FTSBackend
  alias Zaq.Repo

  schema "chunks" do
    belongs_to :document, Document
    field :content, :string
    field :chunk_index, :integer
    field :section_path, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :embedding, Pgvector.Ecto.HalfVector
    field :language, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(document_id content chunk_index)a
  @optional_fields ~w(section_path metadata embedding language)a

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
  Returns the chunk at `chunk_index` within a document, or `nil` if there is none.

  `chunk_index` is the chunk's ordinal position in the source, assigned at
  ingestion time and unique per document. That uniqueness is an invariant of
  the ingestion pipeline rather than a database constraint, so this raises
  `Ecto.MultipleResultsError` if it is ever violated — a duplicate index means
  a document was re-ingested without its old chunks being deleted first, and
  silently returning one of the two would hide it.
  """
  def get_by_index(document_id, chunk_index) do
    from(c in __MODULE__,
      where: c.document_id == ^document_id and c.chunk_index == ^chunk_index
    )
    |> Repo.one()
  end

  @doc """
  Returns every chunk of a document that *covers* `page_number`, ordered by
  `chunk_index`.

  A chunk holds a page range, not a single page: pages run 62-598 tokens in
  real converter output against a ~900-token budget, so one chunk routinely
  swallows a whole page and spills into the next. Matching on the start page
  alone would leave every interior page unreachable. A chunk covering pages
  1-3 is returned for 1, 2 and 3 alike.

  Both bounds are source locators in the `metadata` jsonb rather than columns:
  `start` / `end` hold `"P<page>|L<line>"` strings, and the page is extracted
  in SQL via `substring(... FROM '^P([0-9]+)\\|')`. `substring` returns NULL
  when the key is absent, the value is not a string of that shape, or the
  value is a non-string jsonb node (`->>` renders it as text, which cannot
  match the pattern) — so a malformed row reads NULL and simply does not
  match, without poisoning the query.

  `end` is absent or malformed on some rows; those fall back to their start
  page and behave as single-page chunks. Chunks predating source locators
  have no page at all and never match.

  The page bounds are extracted from JSON metadata with `substring`, so this is
  not an index-optimized page lookup. The query is intentionally scoped by
  `document_id` first and is appropriate for per-document navigation.
  """
  def list_by_page(document_id, page_number) when is_integer(page_number) do
    from(c in __MODULE__,
      where: c.document_id == ^document_id,
      where:
        fragment(
          "(substring(?->>'start' FROM '^P([0-9]+)\\|'))::int <= ?",
          c.metadata,
          ^page_number
        ),
      where:
        fragment(
          """
          COALESCE(
            (substring(?->>'end' FROM '^P([0-9]+)\\|'))::int,
            (substring(?->>'start' FROM '^P([0-9]+)\\|'))::int
          ) >= ?
          """,
          c.metadata,
          c.metadata,
          ^page_number
        ),
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

  @doc "Deletes a single chunk by document and chunk index."
  def delete_by_document_and_index(document_id, chunk_index) do
    from(c in __MODULE__, where: c.document_id == ^document_id and c.chunk_index == ^chunk_index)
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

  # ── Table lifecycle ───────────────────────────────────────────────────

  @doc "Returns true if the chunks table exists in the database."
  def table_exists? do
    {:ok, %{rows: rows}} =
      EctoSQL.query(
        Repo,
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'chunks'",
        []
      )

    rows != []
  end

  @doc "Creates the chunks table with the given dimension. No-op if the table already exists."
  def create_table(dimension) when is_integer(dimension) do
    EctoSQL.query!(Repo, "CREATE EXTENSION IF NOT EXISTS vector", [])

    EctoSQL.query!(
      Repo,
      """
      CREATE TABLE IF NOT EXISTS chunks (
        id bigserial PRIMARY KEY,
        document_id bigint NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        content text NOT NULL,
        chunk_index integer NOT NULL,
        section_path text[] DEFAULT '{}',
        metadata jsonb DEFAULT '{}',
        language varchar(32),
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL
      )
      """,
      []
    )

    EctoSQL.query!(
      Repo,
      "ALTER TABLE chunks ADD COLUMN IF NOT EXISTS embedding halfvec(#{dimension})",
      []
    )

    EctoSQL.query!(
      Repo,
      """
      CREATE INDEX IF NOT EXISTS chunks_embedding_idx
      ON chunks
      USING hnsw (embedding halfvec_l2_ops)
      WITH (m = 16, ef_construction = 64)
      """,
      []
    )

    EctoSQL.query!(
      Repo,
      """
      CREATE INDEX IF NOT EXISTS chunks_document_id_index ON chunks (document_id)
      """,
      []
    )

    FTSBackend.setup_index(Repo, dimension)

    :ok
  end

  @doc "Drops the chunks table. No-op if it does not exist."
  def drop_table do
    EctoSQL.query!(Repo, "DROP TABLE IF EXISTS chunks", [])
    EctoSQL.query!(Repo, "UPDATE documents SET content = NULL", [])
    :ok
  end

  @doc """
  Full reset: drops chunks table, clears document content, then recreates the
  table with the new dimension.
  """
  def reset_table(new_dimension) when is_integer(new_dimension) do
    drop_table()
    create_table(new_dimension)
    Hooks.dispatch_async(:embedding_reset, %{new_dimension: new_dimension}, %{})
  end
end
