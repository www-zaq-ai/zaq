defmodule Zaq.Channels.DiskBridge do
  @moduledoc """
  DataSource bridge for the `disk` provider — ingestion volumes, addressed as a datasource.

  Exposes files on a ZAQ ingestion volume through the same provider-generic commands as an
  external datasource, so a caller passing `provider: "disk", document_id: "42"` uses the
  API it would use for Google Drive and never sees a filesystem path.

  Implements the `create_file/2`, `get_file/2`, `list_files/2`, `download_document/2` and
  `delete_file/2` callbacks of `Zaq.Channels.DataSourceBridge`; it declares no callbacks or
  actions of its own. Each one dispatches to the `:ingestion` role, where
  `Zaq.Ingestion.RecordMaterializer` performs the work and enforces `DocumentAccess`. The
  exception is `download_document/2`, which dispatches nothing and returns the event that
  does.

  ## Configuration

  None. This bridge ignores the config it is passed — the volume comes from ingestion's own
  configuration and the document id carries the rest — so `disk` works with no
  `channel_configs` row and does not appear as a configurable datasource in the BO.
  """

  @behaviour Zaq.Channels.DataSourceBridge

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Utils

  @doc """
  Returns `%{record: record}` where the record is **unmaterialized**.

  Unlike bridges that front a system holding the file, this one reads nothing: the bytes
  live on an ingestion volume, so returning them here would route the payload through
  Channels for no reason. The record carries `content: nil` and a `materializing_event`
  aimed at `{:ingestion, :materialize_record}`; `Zaq.Contracts.Record.Materializer`
  dispatches it, and the metadata (name, mime type, size) arrives from that hop.
  """
  @impl true
  def download_document(config, params) when is_map(config) and is_map(params) do
    {:ok,
     %{
       record: %Record{
         id: to_string(fetch(params, "file_id")),
         kind: :file,
         content: nil,
         materializing_event:
           Event.new(materialize_request(params), :ingestion, opts: [action: :materialize_record])
       }
     }}
  end

  @doc "Lists the given documents as **unmaterialized** records — metadata only."
  @impl true
  def list_files(config, params) when is_map(config) and is_map(params) do
    dispatch(:describe_records, describe_request(params), params)
  end

  @doc "Returns one document as an unmaterialized record."
  @impl true
  def get_file(config, params) when is_map(config) and is_map(params) do
    case list_files(config, Map.put(params, "file_ids", [fetch(params, "file_id")])) do
      {:ok, %RecordPage{records: [record | _]}} -> {:ok, %{record: record}}
      {:ok, %RecordPage{records: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes a file onto an ingestion volume and registers its document row.

  `tags` is passed through to ingestion, which applies it at write time — this is how a
  caller marks a file `"public"` without needing a second round trip.
  """
  @impl true
  def create_file(config, params) when is_map(config) and is_map(params) do
    with {:ok, request} <- persist_request(params),
         {:ok, record} <- dispatch(:persist_record, request, params) do
      {:ok, %{record: record}}
    end
  end

  @doc "Removes the document row and the file behind it."
  @impl true
  def delete_file(config, params) when is_map(config) and is_map(params) do
    dispatch(:delete_record, %{file_id: fetch(params, "file_id")}, params)
  end

  # -- requests --

  defp materialize_request(params) do
    with_caller(params, %{file_id: fetch(params, "file_id")})
  end

  defp describe_request(params) do
    with_caller(params, %{file_ids: fetch(params, "file_ids") || []})
  end

  # Every read request carries who is asking. Ingestion checks it on each one, so leaving it
  # off a request would silently downgrade that call to an unprivileged one rather than fail.
  defp with_caller(params, request) do
    Map.merge(request, %{
      person_id: fetch(params, "person_id"),
      team_ids: fetch(params, "team_ids") || []
    })
  end

  # `volume` and `path` say *where* on a mounted volume to write, which no generic
  # datasource tool supplies — `create_document`, for instance, sends a provider path and no
  # volume at all. Refuse explicitly rather than passing a nil volume down, where it used to
  # surface as a `FunctionClauseError` from `FileExplorer` instead of an error the caller
  # can report.
  defp persist_request(params) do
    volume = fetch(params, "volume")
    path = fetch(params, "path")

    cond do
      not (is_binary(volume) and volume != "") ->
        {:error, :volume_required}

      not (is_binary(path) and path != "") ->
        {:error, :path_required}

      true ->
        {:ok,
         %{
           volume: volume,
           path: path,
           content: fetch(params, "content") || "",
           tags: fetch(params, "tags") || []
         }}
    end
  end

  # -- dispatch --

  defp dispatch(action, request, params) do
    node_router = fetch(params, "node_router") || NodeRouter

    request
    |> Event.new(:ingestion, opts: [action: action])
    |> node_router.dispatch()
    |> Map.fetch!(:response)
  end

  # Params arrive from agent tools with string keys and from internal callers with atom
  # keys; accept either rather than forcing every caller to normalise first.
  defp fetch(params, key), do: Utils.Map.present_value(params, key)
end
