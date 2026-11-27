defmodule Zaq.Ingestion.ChunkRefresh do
  @moduledoc """
  Coordinates replay-safe source refreshes. The document row serializes setup
  and individual chunk writes; old attempt IDs remain reserved after replacement
  or deletion so a replay cannot clear a later version of the source.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Ingestion.{Chunk, ChunkRefreshSource, Document, ExternalPermissions, ExternalSource}
  alias Zaq.Repo

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "chunk_refreshes" do
    field :document_id, :integer
    field :user_id, :integer
    field :source, :string
    field :embedding_model, :string
    field :embedding_dimension, :integer
  end

  @max_markdown_bytes 5 * 1024 * 1024

  @doc """
  Sets up a refresh from an authenticated source Record with loaded permissions
  and converted Markdown.
  Reusing the same ID resumes the current attempt rather than clearing chunks.
  """
  @spec start(String.t(), Zaq.Contracts.Record.t(), String.t(), map()) ::
          {:ok, Document.t()} | {:error, term()}
  def start(attempt_id, record, markdown, context) do
    with {:ok, id} <- cast_id(attempt_id),
         {:ok, user} <- ChunkRefreshSource.authorize(context[:actor]),
         {:ok, identity} <- ChunkRefreshSource.identity(record),
         :ok <- validate_markdown(markdown) do
      case Repo.get(__MODULE__, id) do
        nil -> start_new(id, identity, record, markdown, user, context)
        %__MODULE__{} -> resume(id, identity, user, configuration(context))
      end
    end
  end

  @doc "Revalidates the current administrator and resolves the claimed attempt."
  @spec resume(String.t(), map()) :: {:ok, Document.t()} | {:error, term()}
  def resume(attempt_id, context) do
    with {:ok, id} <- cast_id(attempt_id),
         {:ok, user} <- ChunkRefreshSource.authorize(context[:actor]) do
      resume(id, nil, user, configuration(context))
    end
  end

  @doc """
  Runs a single chunk insert under the current attempt. A previously committed
  index wins over replayed input, including after a lost response.
  """
  @spec insert(String.t(), pos_integer(), map(), (Document.t() ->
                                                    {:ok, term()} | {:error, term()})) ::
          {:ok, :stored | :already_stored} | {:error, term()}
  def insert(attempt_id, index, context, insert_chunk)
      when is_integer(index) and index > 0 and is_function(insert_chunk, 1) do
    with {:ok, id} <- cast_id(attempt_id),
         {:ok, user} <- ChunkRefreshSource.authorize(context[:actor]) do
      Repo.transaction(fn ->
        document = unwrap(current_document(id, user.id, nil, configuration(context)))
        insert_once(document, index, insert_chunk)
      end)
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :chunk_insert_failed}
  end

  defp insert_once(document, index, insert_chunk) do
    if Chunk.get_by_index(document.id, index) do
      :already_stored
    else
      unwrap(insert_chunk.(document))
      :stored
    end
  end

  @doc """
  Keeps in-flight legacy chunk writes from modifying a document after a storage
  Action has replaced it. A full legacy refresh establishes a new version via
  `Document.upsert/1` before it schedules any chunk writes.
  """
  @spec legacy_write(pos_integer(), (-> term()), DateTime.t() | nil) ::
          {:ok, term()} | {:error, :stale_refresh}
  def legacy_write(document_id, write, requested_at \\ nil) when is_function(write, 0) do
    Repo.transaction(fn ->
      document = lock_document(document_id)
      if obsolete_legacy_write?(document, requested_at), do: Repo.rollback(:stale_refresh)
      write.()
    end)
  end

  defp obsolete_legacy_write?(%Document{chunk_refresh_id: id}, _requested_at) when not is_nil(id),
    do: true

  defp obsolete_legacy_write?(
         %Document{chunk_refresh_started_at: %DateTime{} = current},
         %DateTime{} = requested
       ),
       do: DateTime.compare(current, requested) == :gt

  defp obsolete_legacy_write?(_document, _requested_at), do: false

  defp start_new(
         id,
         %{permission_projection: %{"state" => "loaded"}} = identity,
         record,
         markdown,
         user,
         context
       ) do
    with :ok <- ensure_index() do
      config = configuration(context)

      Repo.transaction(fn ->
        initialize_once(id, identity, record, markdown, user, config)
      end)
    end
  end

  defp start_new(_id, _identity, _record, _markdown, _user, _context),
    do: {:error, :missing_permission_projection}

  defp ensure_index do
    if Chunk.table_exists?(), do: :ok, else: {:error, :index_not_configured}
  end

  defp initialize_once(
         id,
         %{source: source, permission_projection: projection},
         record,
         markdown,
         user,
         config
       ) do
    existing = unwrap(Document.insert_new(%{source: source}), :invalid_document)
    document = lock_document(existing.id) || Repo.rollback(:stale_refresh)

    case Repo.get(__MODULE__, id) do
      nil -> initialize(id, document, record, markdown, user, config, projection)
      %__MODULE__{} -> unwrap(current_document(id, user.id, source, config))
    end
  end

  defp initialize(id, document, record, markdown, user, config, %{"entries" => entries}) do
    fields = %{
      id: id,
      document_id: document.id,
      user_id: user.id,
      source: document.source,
      embedding_model: config.model,
      embedding_dimension: config.dimension
    }

    %__MODULE__{}
    |> cast(fields, Map.keys(fields))
    |> unique_constraint(:id, name: :chunk_refreshes_pkey)
    |> Repo.insert()
    |> unwrap(:attempt_conflict)

    # Only the direct parent is authenticated and may influence watch scope.
    metadata =
      %{record | parent_ids: List.wrap(record.parent_id), materialization_handle: nil}
      |> ExternalSource.metadata()

    document =
      document
      |> Document.changeset(%{
        title: record.name,
        content: markdown,
        content_type: "markdown",
        metadata: metadata
      })
      |> put_change(:chunk_refresh_id, id)
      |> put_change(:chunk_refresh_started_at, DateTime.utc_now())
      |> Repo.update()
      |> unwrap(:invalid_document)

    unwrap(
      ExternalPermissions.replace_projection(record, document, entries),
      :permission_sync_failed
    )

    Chunk.delete_by_document(document.id)
    document
  end

  defp resume(id, identity, user, config) do
    Repo.transaction(fn ->
      unwrap(current_document(id, user.id, identity && identity.source, config))
    end)
  end

  defp current_document(id, user_id, source, config) do
    case Repo.get(__MODULE__, id) do
      %__MODULE__{user_id: ^user_id, source: original_source} = attempt
      when is_nil(source) or source == original_source ->
        with {:ok, document} <-
               check_current(lock_document(attempt.document_id), id, original_source),
             :ok <- check_configuration(attempt, config) do
          {:ok, document}
        end

      _ ->
        {:error, :refresh_not_found}
    end
  end

  defp check_configuration(
         %__MODULE__{embedding_model: model, embedding_dimension: dimension},
         %{model: model, dimension: dimension}
       ),
       do: :ok

  defp check_configuration(_attempt, _config), do: {:error, :embedding_configuration_changed}

  defp check_current(%Document{source: source, chunk_refresh_id: id} = doc, id, source),
    do: {:ok, doc}

  defp check_current(_document, _id, _source), do: {:error, :stale_refresh}

  defp lock_document(nil), do: nil

  defp lock_document(id) do
    Repo.one(from document in Document, where: document.id == ^id, lock: "FOR UPDATE")
  end

  defp configuration(context) do
    Map.get_lazy(context, :embedding_configuration, &Zaq.System.get_embedding_config/0)
  end

  defp cast_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} when byte_size(value) == 36 -> {:ok, id}
      _ -> {:error, :invalid_refresh_id}
    end
  end

  defp cast_id(_value), do: {:error, :invalid_refresh_id}

  defp validate_markdown(markdown)
       when is_binary(markdown) and byte_size(markdown) <= @max_markdown_bytes do
    if String.valid?(markdown), do: :ok, else: {:error, :invalid_markdown}
  end

  defp validate_markdown(_markdown), do: {:error, :invalid_markdown}

  defp unwrap(result, fallback \\ nil)
  defp unwrap({:ok, value}, _fallback), do: value
  defp unwrap({:error, reason}, fallback), do: Repo.rollback(fallback || reason)
end
