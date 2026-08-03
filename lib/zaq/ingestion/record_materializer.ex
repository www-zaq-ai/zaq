defmodule Zaq.Ingestion.RecordMaterializer do
  @moduledoc """
  Turns document ids into `Zaq.Contracts.Record`s, and back.

  The ingestion side of unmaterialized records, and the single home for the file_id ↔ record
  mapping. A caller holding only a `file_id` uses it to describe a document
  (`describe/2`), read its bytes (`materialize/2`), write a new one (`persist/2`) or remove
  one (`delete/2`).

  Callers never see a path: resolving a document's `source` to a volume-relative location
  happens here because the ingestion role is the only one guaranteed to have the volume
  mounted.

  ## Permissions

  Every function that names an existing document — `materialize/2`, `describe/2` and
  `delete/2` — goes through `Zaq.Ingestion.DocumentAccess`. Deleting is gated on the same
  check as reading: a caller may only remove what it may see. `persist/2` is the exception,
  because it creates a document rather than naming one; the volume and path it writes to
  are the caller's authorisation, and `Zaq.Ingestion.FileExplorer.resolve_path/2` is what
  keeps that inside a mounted volume.

  No function here accepts a `skip_permissions` option, and a `skip_permissions` key
  present in `params` is ignored — params arrive from a dispatched event, so honouring one
  would let any event author grant itself access.

  A `nil` `person_id` is not a grant; it resolves like any other unprivileged caller, so the
  document must carry the `"public"` tag or a matching permission row. Skill reference files
  are readable by an agent because the BO tags them public at write time, not because this
  module knows anything about skills.
  """

  import Ecto.Query

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.DocumentAccess
  alias Zaq.Ingestion.FileExplorer
  alias Zaq.Ingestion.SourcePath
  alias Zaq.Repo

  @provider "disk"

  @doc """
  Returns the document as a record with its `content` populated.

  Fails with `:forbidden` when the caller may not read it, `:not_found` when no such
  document exists, and `{:file_unreadable, reason}` when the row exists but the bytes do
  not.
  """
  @spec materialize(map(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def materialize(params, opts \\ []) do
    with {:ok, doc} <- fetch_permitted(params),
         {:ok, full_path} <- resolve_full_path(doc.source, opts),
         {:ok, content} <- read_file(full_path) do
      {:ok, build_record(doc, content)}
    end
  end

  @doc """
  Returns a page of **unmaterialized** records — metadata only, `content: nil`.

  Records come back in the order the caller asked for them, not the order Postgres chose:
  a caller rendering them as a list must not see the rows reshuffle between calls.

  Ids the caller cannot access, and ids with no document, are omitted rather than failing
  the page: a single stale reference must not make a whole skill unloadable. They are named
  in `stats.missing` so a caller can report the gap rather than silently rendering a shorter
  list than it asked for.
  """
  @spec describe(map(), keyword()) :: {:ok, RecordPage.t()} | {:error, term()}
  def describe(params, opts \\ [])

  def describe(%{file_ids: []}, _opts), do: {:ok, empty_page()}

  def describe(%{file_ids: file_ids} = params, opts) do
    requested = file_ids |> Enum.map(&to_string/1) |> Enum.uniq()
    ids = requested |> Enum.map(&parse_id/1) |> Enum.reject(&is_nil/1)

    found = ids |> permitted_documents(params) |> Map.new(&{&1.id, &1})

    records = for id <- ids, doc = Map.get(found, id), do: build_record(doc, nil, opts)
    missing = Enum.reject(requested, &Map.has_key?(found, parse_id(&1)))

    {:ok,
     %{
       empty_page()
       | records: records,
         stats: %{scanned: length(requested), returned: length(records), missing: missing}
     }}
  end

  @doc """
  Writes `content` into `volume` at `path`, registers the document row, and applies `tags`.

  One call rather than a write followed by a separate registration: a crash between the two
  would otherwise leave a file on disk that no document row points at. The written path is
  de-duplicated, so uploading the same filename twice produces two documents rather than
  silently overwriting the first.
  """
  @spec persist(map(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def persist(params, opts \\ [])

  def persist(%{volume: volume, path: path} = params, opts)
      when is_binary(volume) and is_binary(path) do
    content = Map.get(params, :content, "")
    tags = Map.get(params, :tags, [])

    with {:ok, written} <- FileExplorer.upload_unique(volume, path, content),
         {:ok, source} <- SourcePath.absolute_to_source(written),
         {:ok, doc} <- Document.insert_new(%{source: source}),
         {:ok, doc} <- apply_tags(doc, tags) do
      {:ok, build_record(doc, nil, opts)}
    end
  end

  # Params arrive here from a dispatched event, so a caller that omits a volume or path —
  # or sends the wrong shape entirely — must get an error, not a `FunctionClauseError`
  # raised from deep inside `FileExplorer`.
  def persist(_params, _opts), do: {:error, :invalid_persist_request}

  @doc """
  Removes the document row and the file behind it.

  Permission-checked like a read, and for the same reason: a caller that may not see a
  document must not be able to delete it. Fails with `:forbidden` when it may not.

  Idempotent: deleting an id that is already gone succeeds. A row that could not be deleted
  returns `{:error, changeset}` rather than `:ok` — a caller that drops its reference on
  `:ok` would otherwise strand a row nothing points at.
  """
  @spec delete(map(), keyword()) :: :ok | {:error, term()}
  def delete(params, opts \\ [])

  def delete(%{file_id: _file_id} = params, opts) do
    case fetch_permitted(params) do
      {:ok, doc} ->
        # The file first: a row whose bytes are already gone is recoverable, a file no row
        # points at is not.
        case resolve_full_path(doc.source, opts) do
          {:ok, full_path} -> File.rm(full_path)
          _ -> :ok
        end

        case Document.delete(doc) do
          {:ok, _doc} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Params arrive from a dispatched event, so a request with no `file_id` at all must get an
  # error rather than a `FunctionClauseError`.
  def delete(_params, _opts), do: {:error, :invalid_delete_request}

  # -- permissions --

  defp fetch_permitted(params) do
    with {:ok, doc} <- fetch_document(Map.get(params, :file_id)) do
      if permitted?(doc.id, params), do: {:ok, doc}, else: {:error, :forbidden}
    end
  end

  defp permitted?(doc_id, params) do
    doc_id in permitted_ids([doc_id], params)
  end

  defp permitted_documents(ids, params) do
    permitted = permitted_ids(ids, params)

    if permitted == [] do
      []
    else
      Repo.all(from(d in Document, where: d.id in ^permitted))
    end
  end

  # `skip_permissions` is deliberately not read from params — see the moduledoc.
  defp permitted_ids([], _params), do: []

  defp permitted_ids(ids, params) do
    DocumentAccess.list_permitted_document_ids(
      Map.get(params, :person_id),
      Map.get(params, :team_ids) || [],
      ids
    )
  end

  # -- documents --

  defp fetch_document(file_id) do
    case parse_id(file_id) do
      nil ->
        {:error, :not_found}

      id ->
        case Document.get(id) do
          nil -> {:error, :not_found}
          doc -> {:ok, doc}
        end
    end
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  defp apply_tags(doc, []), do: {:ok, doc}

  defp apply_tags(doc, tags) do
    merged = Enum.uniq((doc.tags || []) ++ tags)

    if merged == doc.tags do
      {:ok, doc}
    else
      doc |> Ecto.Changeset.change(tags: merged) |> Repo.update()
    end
  end

  # -- paths --

  defp resolve_full_path(source, opts) do
    volumes = Keyword.get(opts, :volumes)

    case SourcePath.split_source(source, nil, volumes) do
      {nil, relative} -> FileExplorer.resolve_path(relative)
      {volume, relative} -> FileExplorer.resolve_path(volume, relative)
    end
  end

  defp read_file(full_path) do
    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:file_unreadable, reason}}
    end
  end

  # -- records --

  defp build_record(doc, content, opts \\ []) do
    {volume, relative} = SourcePath.split_source(doc.source, nil, Keyword.get(opts, :volumes))
    name = Path.basename(doc.source)

    %Record{
      id: to_string(doc.id),
      kind: :file,
      name: name,
      path: relative,
      content: content,
      mime_type: MIME.from_path(name),
      size: size_of(content),
      modified_at: doc.updated_at,
      attributes: %{
        "provider" => @provider,
        "volume" => volume,
        "source" => doc.source
      }
    }
  end

  defp size_of(content) when is_binary(content), do: byte_size(content)
  defp size_of(_), do: nil

  defp empty_page do
    %RecordPage{
      resource_type: :file,
      records: [],
      stats: %{scanned: 0, returned: 0, missing: []}
    }
  end
end
