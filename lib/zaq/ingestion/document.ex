defmodule Zaq.Ingestion.Document do
  @moduledoc """
  Ecto schema for ingested documents.

  Stores the original uploaded document content and metadata.
  Each document has many associated chunks (see `Zaq.Ingestion.Chunk`).

  `watch_status`, `watch_requested_at`, `watch_updated_at`, and `watch_error`
  are user-facing watch state for BO. Provider runtime state such as channel ids
  and checkpoints is intentionally stored in `Zaq.Engine.DataSources.WatchChannel`,
  not on documents. External provider documents may carry provider parent ids in
  metadata so provider delete/tombstone signals can remove moved or deleted
  watched descendants even when the signal is sparse.

  Replaces the legacy `dubai_health_files` table from zaq_agent.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Ingestion.{Chunk, Labels}
  alias Zaq.Ingestion.Labels.AssignmentValue
  alias Zaq.Permissions.DocumentPermission, as: Permission
  alias Zaq.Repo

  schema "documents" do
    field :title, :string
    field :source, :string
    field :content, :string
    field :content_type, :string, default: "markdown"
    field :metadata, :map, default: %{}
    field :watch_status, :string, default: "unwatched"
    field :watch_requested_at, :utc_datetime
    field :watch_updated_at, :utc_datetime
    field :watch_error, :string

    has_many :chunks, Chunk
    has_many :permissions, Permission, foreign_key: :resource_id, references: :id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(source)a
  @watch_statuses ~w(unwatched pending watched error)

  @optional_fields ~w(title content content_type metadata watch_status watch_requested_at watch_updated_at watch_error)a

  def changeset(document, attrs) do
    document
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:content_type, ~w(markdown text html))
    |> validate_inclusion(:watch_status, @watch_statuses)
    |> unique_constraint(:source)
    |> maybe_set_title()
  end

  @doc "Returns supported user-facing document watch statuses."
  def watch_statuses, do: @watch_statuses

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
  Inserts a document only if no record with the same source exists.
  Used by upload tracking to make a file visible in the browser without
  overwriting content from a prior ingestion run.
  """
  def insert_new(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :source, returning: true)
    |> case do
      {:ok, %__MODULE__{id: nil}} ->
        {:ok, Repo.get_by!(__MODULE__, source: attrs[:source] || attrs["source"])}

      {:ok, %__MODULE__{} = doc} ->
        {:ok, doc}

      {:error, changeset} ->
        {:error, changeset}
    end
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
  Returns documents for the given sources.
  """
  def list_by_sources(sources) when is_list(sources) do
    sources = Enum.uniq(sources)

    from(d in __MODULE__, where: d.source in ^sources)
    |> Repo.all()
  end

  @doc """
  Maps each of `sources` to the id of the document holding it.

  Sources with no document row are absent from the result — a file on a volume is reachable
  whether or not it was ever ingested, so a miss is an ordinary answer rather than an error.
  One query covers the whole list, which is what keeps a directory listing from running a
  lookup per file.
  """
  @spec ids_by_source([String.t()]) :: %{String.t() => integer()}
  def ids_by_source(sources) when is_list(sources) do
    sources
    |> list_by_sources()
    |> Map.new(&{&1.source, &1.id})
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
  Returns a query that bulk-renames document sources beginning with `old_prefix/`.
  Intended for use inside an `Ecto.Multi` — does not execute any DB call.
  """
  def rename_source_prefix_query(old_prefix, new_prefix) do
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

  @max_label_id 9_223_372_036_854_775_807

  @doc "Validates label ID, value and any/all filters for document queries."
  @spec validate_label_filters(map() | nil) :: :ok | {:error, term()}
  def validate_label_filters(nil), do: :ok

  def validate_label_filters(filters) when is_map(filters) do
    ids = fetch(filters, "label_ids")
    match = fetch(filters, "label_match")
    values = fetch(filters, "label_values")

    cond do
      ids != :error and not valid_ids?(ids) ->
        {:error, {:invalid_filter, "label_ids"}}

      values != :error and not valid_values?(values) ->
        {:error, {:invalid_filter, "label_values"}}

      invalid_match?(match, ids, values) ->
        {:error, {:invalid_filter, "label_match"}}

      true ->
        :ok
    end
  end

  defp invalid_match?(match, ids, values) do
    match not in [:error, {:ok, "any"}, {:ok, "all"}] or
      (match != :error and ids == :error and values == :error)
  end

  @doc """
  Applies validated label filters to an already authorized document query.

  Only selected assignments match. Subqueries preserve unique documents before
  counting and pagination; empty lists match none and omitted lists do not filter.
  """
  @spec filter_by_labels(Ecto.Queryable.t(), map()) :: Ecto.Query.t()
  def filter_by_labels(query, filters) do
    query =
      case fetch(filters, "label_ids") do
        :error -> query
        {:ok, ids} -> matching_documents(query, Enum.uniq(ids), fetch(filters, "label_match"))
      end

    case fetch(filters, "label_values") do
      :error ->
        query

      {:ok, pairs} ->
        matching_values(query, normalized_pairs(pairs), fetch(filters, "label_match"))
    end
  end

  defp matching_documents(query, ids, match) do
    assignments = Labels.matching_document_ids(ids, match)
    from d in query, where: d.id in subquery(assignments)
  end

  defp matching_values(query, pairs, match) do
    assignments = Labels.matching_document_value_ids(pairs, match)
    from d in query, where: d.id in subquery(assignments)
  end

  defp valid_values?({:ok, pairs}) when is_list(pairs) and length(pairs) <= 100,
    do: Enum.all?(pairs, &valid_pair?/1)

  defp valid_values?(_), do: false

  defp valid_pair?(pair) when is_map(pair) do
    with true <- Enum.all?(Map.keys(pair), &(&1 in ["label_id", "value", :label_id, :value])),
         {:ok, id} <- fetch(pair, "label_id"),
         {:ok, value} <- fetch(pair, "value") do
      valid_ids?({:ok, [id]}) and AssignmentValue.valid?(value)
    else
      _ -> false
    end
  end

  defp valid_pair?(_), do: false

  defp normalized_pairs(pairs) do
    pairs
    |> Enum.map(fn pair ->
      {:ok, id} = fetch(pair, "label_id")
      {:ok, value} = fetch(pair, "value")
      {id, AssignmentValue.normalize(value)}
    end)
    |> Enum.uniq_by(fn {id, value} -> {id, AssignmentValue.equality_key(value)} end)
  end

  defp valid_ids?({:ok, ids}) when is_list(ids) and length(ids) <= 100,
    do: Enum.all?(ids, &(is_integer(&1) and &1 > 0 and &1 <= @max_label_id))

  defp valid_ids?(_), do: false

  defp fetch(filters, key) do
    case Map.fetch(filters, key) do
      :error -> Map.fetch(filters, key_atom(key))
      value -> value
    end
  end

  defp key_atom("label_ids"), do: :label_ids
  defp key_atom("label_values"), do: :label_values
  defp key_atom("label_match"), do: :label_match
  defp key_atom("label_id"), do: :label_id
  defp key_atom("value"), do: :value
end
