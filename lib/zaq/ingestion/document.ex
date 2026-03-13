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

  alias Zaq.Accounts.Role
  alias Zaq.Ingestion.Chunk
  alias Zaq.Repo

  schema "documents" do
    field :title, :string
    field :source, :string
    field :content, :string
    field :content_type, :string, default: "markdown"
    field :metadata, :map, default: %{}
    belongs_to :role, Role

    has_many :chunks, Chunk

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(source content)a
  @optional_fields ~w(title content_type metadata role_id)a

  def changeset(document, attrs) do
    document
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:content_type, ~w(markdown text html))
    |> unique_constraint(:source)
    |> foreign_key_constraint(:role_id)
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
      on_conflict:
        {:replace, [:content, :title, :content_type, :metadata, :role_id, :updated_at]},
      conflict_target: :source
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
