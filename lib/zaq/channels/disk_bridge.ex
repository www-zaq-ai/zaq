defmodule Zaq.Channels.DiskBridge do
  @moduledoc """
  DataSource bridge for the `disk` provider — ingestion volumes, addressed as a datasource.

  Every other datasource bridge fronts an external system. This one fronts ZAQ's own
  ingestion role, so that files living on an ingestion volume can be reached through the
  same provider-generic commands as a Google Drive or SharePoint document. A caller asking
  for `provider: "disk", document_id: "42"` uses exactly the API it would use for any other
  provider, and never learns that a filesystem is involved.

  ## Why it needs no new plumbing

  `Zaq.Channels.DataSourceBridge` already declares `create_file/2`, `get_file/2`,
  `list_files/2`, `download_document/2` and `delete_file/2`, and `Zaq.Channels.Api`
  already routes all five. This module only implements them; it adds no callbacks and no
  actions.

  ## Configuration

  There is nothing to configure, and nothing anywhere declares that. This bridge never
  reads the config it is passed — the volume lives in ingestion's own configuration and the
  document id carries everything else — so `disk` needs no `channel_configs` row and works
  out of the box. A row would be a phantom in the BO datasource list, where an operator
  could disable or delete it and silently break every skill that reads a reference file.

  Bridges that *do* authenticate reject a config with no row themselves, on the grounds that
  they cannot find their grant without one — see `Zaq.Channels.JidoConnectBridge`. That is
  why `Zaq.Channels.DataSourceBridge` can hand every bridge whatever config exists without
  knowing which of them care.

  Each callback dispatches to the `:ingestion` role, where
  `Zaq.Ingestion.RecordMaterializer` does the work and enforces `DocumentAccess`.
  """

  @behaviour Zaq.Channels.DataSourceBridge

  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc """
  Returns the document's bytes as a record.

  Wrapped as `%{record: record}` to match the shape every other datasource bridge returns
  for this callback.
  """
  @impl true
  def download_document(config, params) when is_map(config) and is_map(params) do
    case dispatch(:materialize_record, materialize_request(params), params) do
      {:ok, record} -> {:ok, %{record: record}}
      {:error, reason} -> {:error, reason}
    end
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
    %{
      file_id: fetch(params, "file_id"),
      person_id: fetch(params, "person_id"),
      team_ids: fetch(params, "team_ids") || []
    }
  end

  defp describe_request(params) do
    %{
      file_ids: fetch(params, "file_ids") || [],
      person_id: fetch(params, "person_id"),
      team_ids: fetch(params, "team_ids") || []
    }
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
  defp fetch(params, key) do
    Map.get(params, key) || Map.get(params, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(params, key)
  end
end
