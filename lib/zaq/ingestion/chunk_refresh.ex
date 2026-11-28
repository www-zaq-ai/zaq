defmodule Zaq.Ingestion.ChunkRefresh do
  @moduledoc """
  Coordinates replay-safe source refreshes. Reserve before acquisition when a
  chain is known to index: its ordering then reflects when indexing was
  requested, even if download or embedding finishes out of order. Independent
  calls establish ordering when storage starts. Reservation leaves the current
  index readable; setup and each write are fenced against superseded attempts.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Ingestion.{
    Chunk,
    ChunkLanguages,
    ChunkRefreshSource,
    Document,
    ExternalPermissions,
    ExternalSource
  }

  alias Zaq.Repo

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "chunk_refreshes" do
    field :document_id, :integer
    field :user_id, :integer
    field :source, :string
    field :embedding_model, :string
    field :embedding_dimension, :integer
    field :generation, :integer
    field :reserved_at, :utc_datetime_usec
    field :reserved_document_id, :integer
    field :initialized, :boolean
  end

  @max_markdown_bytes 5 * 1024 * 1024

  @doc """
  Reserves the attempt ID for a verified source and the current administrator.
  Does not create or modify the indexed document, chunks, or grants. Repeating
  a reservation never moves it ahead of a newer attempt.
  """
  @spec reserve(String.t(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def reserve(attempt_id, record, context) do
    with {:ok, id} <- cast_id(attempt_id),
         {:ok, user} <- ChunkRefreshSource.authorize(context[:actor]),
         {:ok, source} <- ChunkRefreshSource.source_key(record) do
      config = configuration(context)

      Repo.transaction(fn ->
        lock_source(source)
        reserve_attempt(id, source, user, config)
        id
      end)
    end
  end

  defp reserve_attempt(id, source, user, config) do
    case Repo.get(__MODULE__, id) do
      nil ->
        document = lock_source_document(source)

        insert_attempt(id, source, user, config, %{
          reserved_at: DateTime.utc_now(),
          reserved_document_id: document && document.id,
          initialized: false
        })

      %__MODULE__{} = attempt ->
        unwrap(check_reservation(attempt, user.id, source, config))
        check_reserved_target!(attempt, user, config)
    end
  end

  defp check_reserved_target!(%__MODULE__{initialized: true} = attempt, user, config),
    do: unwrap(current_document(attempt, user.id, attempt.source, config))

  defp check_reserved_target!(attempt, _user, _config),
    do: check_reserved_document!(attempt, lock_source_document(attempt.source))

  @doc """
  Sets up a refresh from an authenticated source Record with loaded permissions
  and converted Markdown.
  Reusing the same ID resumes the current attempt rather than clearing chunks.
  """
  @spec start(String.t(), map(), String.t(), map(), String.t() | nil) ::
          {:ok, Document.t()} | {:error, term()}
  def start(attempt_id, record, markdown, context, reservation_id \\ nil) do
    with {:ok, id} <- cast_id(attempt_id),
         :ok <- validate_reservation_id(id, reservation_id),
         {:ok, user} <- ChunkRefreshSource.authorize(context[:actor]),
         {:ok, identity} <- ChunkRefreshSource.identity(record),
         :ok <- validate_markdown(markdown) do
      start_refresh(id, identity, markdown, user, context, reservation_id)
    end
  end

  @doc "Revalidates the current administrator and resolves the claimed attempt."
  @spec resume(String.t(), map(), String.t() | nil) :: {:ok, Document.t()} | {:error, term()}
  def resume(attempt_id, context, reservation_id \\ nil) do
    with {:ok, id} <- cast_id(attempt_id),
         :ok <- validate_reservation_id(id, reservation_id),
         {:ok, user} <- ChunkRefreshSource.authorize(context[:actor]) do
      config = configuration(context)

      Repo.transaction(fn ->
        attempt = Repo.get(__MODULE__, id)
        unwrap(check_supplied_reservation(reservation_id, attempt, user.id, nil, config))
        unwrap(current_document(attempt, user.id, nil, config))
      end)
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
        attempt = Repo.get(__MODULE__, id)
        document = unwrap(current_document(attempt, user.id, nil, configuration(context)))
        insert_once(document, index, insert_chunk)
      end)
      |> tap(fn
        {:ok, :stored} -> ChunkLanguages.invalidate()
        _ -> :ok
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
  Keeps in-flight ingestion jobs from modifying a document after a storage
  Action has replaced it. A full ingestion run establishes a new version via
  `Document.upsert/1` before it schedules any chunk writes.
  """
  @spec pipeline_write(pos_integer(), (-> term()), DateTime.t() | nil) ::
          {:ok, term()} | {:error, :stale_refresh}
  def pipeline_write(document_id, write, requested_at) when is_function(write, 0) do
    Repo.transaction(fn ->
      document = lock_document(document_id)
      if obsolete_pipeline_write?(document, requested_at), do: :stale, else: {:written, write.()}
    end)
    |> case do
      {:ok, :stale} -> {:error, :stale_refresh}
      {:ok, {:written, result}} -> {:ok, result}
      {:error, _reason} = error -> error
    end
  end

  @doc "Checks a queued write before embedding. The write must still check under lock."
  @spec check_pipeline_write(pos_integer() | nil, DateTime.t()) ::
          :ok | {:error, :stale_refresh}
  def check_pipeline_write(nil, _requested_at), do: {:error, :stale_refresh}

  def check_pipeline_write(document_id, requested_at) do
    document =
      Repo.one(
        from document in Document,
          where: document.id == ^document_id,
          select: struct(document, [:chunk_refresh_id, :chunk_refresh_started_at])
      )

    if obsolete_pipeline_write?(document, requested_at),
      do: {:error, :stale_refresh},
      else: :ok
  end

  defp obsolete_pipeline_write?(nil, %DateTime{}), do: true

  defp obsolete_pipeline_write?(%Document{chunk_refresh_id: id}, _requested_at)
       when not is_nil(id),
       do: true

  defp obsolete_pipeline_write?(
         %Document{chunk_refresh_started_at: %DateTime{} = current},
         %DateTime{} = requested
       ),
       do: DateTime.compare(current, requested) == :gt

  defp obsolete_pipeline_write?(_document, _requested_at), do: false

  defp start_refresh(id, identity, markdown, user, context, reservation_id) do
    config = configuration(context)

    Repo.transaction(fn ->
      lock_source(identity.source)

      case {Repo.get(__MODULE__, id), reservation_id} do
        {nil, nil} ->
          start_standalone(id, identity, markdown, user, config)

        {nil, _reservation_id} ->
          Repo.rollback(:invalid_refresh_reservation)

        {%__MODULE__{} = attempt, reservation_id} ->
          start_existing(attempt, identity, markdown, user, config, reservation_id)
      end
    end)
    |> case do
      {:ok, {document, deleted_count}} ->
        if deleted_count > 0, do: ChunkLanguages.invalidate()
        {:ok, document}

      error ->
        error
    end
  end

  defp start_standalone(id, identity, markdown, user, config) do
    initialize_refresh(identity, markdown, fn document ->
      insert_attempt(id, identity.source, user, config, %{
        document_id: document.id,
        initialized: true
      })
    end)
  end

  defp start_existing(
         %__MODULE__{initialized: true} = attempt,
         identity,
         _markdown,
         user,
         config,
         reservation_id
       ) do
    unwrap(check_supplied_reservation(reservation_id, attempt, user.id, identity.source, config))
    {unwrap(current_document(attempt, user.id, identity.source, config)), 0}
  end

  defp start_existing(_attempt, _identity, _markdown, _user, _config, nil),
    do: Repo.rollback(:reservation_required)

  defp start_existing(attempt, identity, markdown, user, config, _reservation_id) do
    unwrap(check_reservation(attempt, user.id, identity.source, config))

    initialize_refresh(identity, markdown, fn document ->
      check_reserved_document!(attempt, document)
      attempt |> change(%{initialized: true, document_id: document.id}) |> Repo.update!()
    end)
  end

  defp ensure_index do
    if Chunk.table_exists?(), do: :ok, else: {:error, :index_not_configured}
  end

  defp initialize_refresh(identity, markdown, persist_attempt) do
    if identity.permission_projection["state"] != "loaded",
      do: Repo.rollback(:missing_permission_projection)

    unwrap(ensure_index())
    existing = unwrap(Document.insert_new(%{source: identity.source}), :invalid_document)
    document = lock_document(existing.id) || Repo.rollback(:stale_refresh)

    attempt = persist_attempt.(document)
    initialize(attempt.id, document, identity, markdown)
  end

  defp insert_attempt(id, source, user, config, attrs) do
    fields = %{
      id: id,
      user_id: user.id,
      source: source,
      embedding_model: config.model,
      embedding_dimension: config.dimension
    }

    fields = Map.merge(fields, attrs)

    %__MODULE__{}
    |> cast(fields, Map.keys(fields))
    |> unique_constraint(:id, name: :chunk_refreshes_pkey)
    |> Repo.insert()
    |> unwrap(:attempt_conflict)
  end

  defp check_reserved_document!(attempt, document) do
    replaced? =
      not is_nil(attempt.reserved_document_id) and
        attempt.reserved_document_id != (document && document.id)

    started_at = document && document.chunk_refresh_started_at
    superseded? = not is_nil(started_at) and DateTime.after?(started_at, attempt.reserved_at)

    if replaced? or superseded?, do: Repo.rollback(:stale_refresh)
  end

  defp initialize(id, document, identity, markdown) do
    document =
      document
      |> Document.changeset(%{
        title: identity.record.name,
        content: markdown,
        content_type: "markdown",
        metadata: ExternalSource.metadata(identity.record)
      })
      |> put_change(:chunk_refresh_id, id)
      |> put_change(:chunk_refresh_started_at, DateTime.utc_now())
      |> Repo.update()
      |> unwrap(:invalid_document)

    unwrap(ExternalPermissions.replace_projection(document, identity), :permission_sync_failed)

    {deleted_count, _} = Chunk.delete_by_document(document.id, invalidate?: false)
    {document, deleted_count}
  end

  defp current_document(
         %__MODULE__{initialized: true, user_id: user_id} = attempt,
         user_id,
         source,
         config
       )
       when is_nil(source) or source == attempt.source do
    with {:ok, document} <-
           check_current(lock_document(attempt.document_id), attempt.id, attempt.source),
         :ok <- check_latest(attempt),
         :ok <- check_configuration(attempt, config) do
      {:ok, document}
    end
  end

  defp current_document(_attempt, _user_id, _source, _config),
    do: {:error, :refresh_not_found}

  defp check_configuration(
         %__MODULE__{embedding_model: model, embedding_dimension: dimension},
         %{model: model, dimension: dimension}
       ),
       do: :ok

  defp check_configuration(_attempt, _config), do: {:error, :embedding_configuration_changed}

  defp check_supplied_reservation(nil, _attempt, _user_id, _source, _config), do: :ok

  defp check_supplied_reservation(_reservation_id, attempt, user_id, source, config),
    do: check_reservation(attempt, user_id, source, config)

  defp check_reservation(
         %__MODULE__{reserved_at: %DateTime{}, user_id: user_id} = attempt,
         user_id,
         source,
         config
       )
       when is_nil(source) or source == attempt.source do
    with :ok <- check_latest(attempt), do: check_configuration(attempt, config)
  end

  defp check_reservation(_attempt, _user_id, _source, _config),
    do: {:error, :invalid_refresh_reservation}

  defp check_latest(%__MODULE__{id: id, source: source}) do
    latest_id =
      Repo.one(
        from attempt in __MODULE__,
          where: attempt.source == ^source,
          order_by: [desc: attempt.generation],
          limit: 1,
          select: attempt.id
      )

    if latest_id == id, do: :ok, else: {:error, :stale_refresh}
  end

  defp check_current(%Document{source: source, chunk_refresh_id: id} = doc, id, source),
    do: {:ok, doc}

  defp check_current(_document, _id, _source), do: {:error, :stale_refresh}

  defp lock_document(nil), do: nil

  defp lock_document(id) do
    Repo.one(from document in Document, where: document.id == ^id, lock: "FOR UPDATE")
  end

  defp lock_source_document(source) do
    Repo.one(from document in Document, where: document.source == ^source, lock: "FOR UPDATE")
  end

  defp lock_source(source) do
    # An advisory lock serializes starts even when a source has no document yet.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "chunk_refresh:" <> source
    ])
  end

  defp validate_reservation_id(_id, nil), do: :ok

  defp validate_reservation_id(id, reservation_id) do
    if cast_id(reservation_id) == {:ok, id}, do: :ok, else: {:error, :invalid_refresh_reservation}
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
  defp unwrap(:ok, _fallback), do: :ok
  defp unwrap({:ok, value}, _fallback), do: value
  defp unwrap({:error, reason}, fallback), do: Repo.rollback(fallback || reason)
end
