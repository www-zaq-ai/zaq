defmodule Zaq.Ingestion.Document do
  @moduledoc """
  Ecto schema for ingested documents.

  Stores the original uploaded document content and metadata.
  Each document has many associated chunks (see `Zaq.Ingestion.Chunk`).

  Replaces the legacy `dubai_health_files` table from zaq_agent.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Ingestion.{Chunk, Permission}
  alias Zaq.Repo

  schema "documents" do
    field :title, :string
    field :source, :string
    field :content, :string
    field :content_type, :string, default: "markdown"
    field :metadata, :map, default: %{}
    field :tags, {:array, :string}, default: []

    has_many :chunks, Chunk
    has_many :permissions, Permission

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(source)a
  @optional_fields ~w(title content content_type metadata tags)a

  def changeset(document, attrs) do
    document
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:content_type, ~w(markdown text html))
    |> unique_constraint(:source)
    |> maybe_set_title()
  end

  # -- Query API --

  @doc """
  Creates a new document.
  """
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates or updates a document by source (upsert).
  If a document with the same source exists, its content and metadata are updated.
  """
  def upsert(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:content, :title, :content_type, :metadata, :updated_at]},
      conflict_target: :source,
      returning: true
    )
  end

  @doc """
  Returns a document by ID.
  """
  def get(id), do: Repo.get(__MODULE__, id)

  @doc """
  Returns a document by ID, raises if not found.
  """
  def get!(id), do: Repo.get!(__MODULE__, id)

  @doc """
  Returns a document by source.
  """
  def get_by_source(source) do
    Repo.get_by(__MODULE__, source: source)
  end

  @doc """
  Lists all documents, ordered by most recently updated.
  """
  def list do
    from(d in __MODULE__, order_by: [desc: d.updated_at])
    |> Repo.all()
  end

  @doc """
  Deletes a document and its associated chunks (via cascade).
  """
  def delete(%__MODULE__{} = document) do
    Repo.delete(document)
  end

  @doc """
  Bulk-renames document sources that begin with `old_prefix/` by replacing the
  prefix with `new_prefix`. Used when a folder is renamed on the filesystem.
  Returns `{count, nil}`.
  """
  def rename_source_prefix(old_prefix, new_prefix) do
    from(d in __MODULE__,
      where: like(d.source, ^"#{old_prefix}/%"),
      update: [
        set: [
          source:
            fragment(
              "? || substring(source from char_length(?) + 1)",
              ^new_prefix,
              ^old_prefix
            ),
          updated_at: ^DateTime.utc_now()
        ]
      ]
    )
    |> Repo.update_all([])
  end

  @doc """
  Bulk-renames the `sidecar_source` and `source_document_source` metadata
  pointers that begin with `old_prefix/`. Keeps sidecar cross-references valid
  after a folder rename. Returns `{count, nil}` for each updated key.
  """
  def rename_metadata_source_prefix(old_prefix, new_prefix) do
    for key <- ["sidecar_source", "source_document_source"] do
      from(d in __MODULE__,
        where: like(fragment("?->>?::text", d.metadata, ^key), ^"#{old_prefix}/%"),
        update: [
          set: [
            metadata:
              fragment(
                "metadata || jsonb_build_object(?::text, ? || substring(metadata->>?::text from char_length(?::text) + 1))",
                ^key,
                ^new_prefix,
                ^key,
                ^old_prefix
              ),
            updated_at: ^DateTime.utc_now()
          ]
        ]
      )
      |> Repo.update_all([])
    end
  end

  @doc """
  Builds an Ecto `dynamic` OR-condition matching documents whose source starts
  with any of the given prefixes (i.e. `source LIKE "prefix/%"`).
  """
  def source_prefix_conditions(prefixes) do
    prefixes
    |> Enum.map(fn prefix -> dynamic([d], like(d.source, ^"#{prefix}/%")) end)
    |> Enum.reduce(fn cond, acc -> dynamic([d], ^acc or ^cond) end)
  end

  # -- Private --

  # Derive title from source filename if not provided
  defp maybe_set_title(changeset) do
    case get_field(changeset, :title) do
      nil ->
        source = get_field(changeset, :source)

        if source do
          title = source |> Path.basename() |> Path.rootname()
          put_change(changeset, :title, title)
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
