defmodule Zaq.Channels.DiskBridge do
  @moduledoc """
  Data-source bridge over the ingestion volumes mounted on this install.

  Unlike a bridge fronting a remote provider, the files here are already inside ZAQ. That
  changes two things.

  Nothing is read on the channels node: every callback dispatches a `%Zaq.Event{}` to
  `:ingestion`, which owns `FileExplorer` and the `documents` table. `download_document/2`
  goes further and returns the record unmaterialized — `content: nil` plus a
  `materializing_event` — so a listing does not drag file bytes across a node boundary for a
  caller that only wanted metadata.

  A file is named by its `documents.id`, the same handle `list_files/2` returns and
  `get_file/2`, `update_file/2`, and `delete_file/2` accept. Folders and files with no
  document row fall back to a volume-path id, since there is no document to name.
  """

  @behaviour Zaq.Channels.DataSourceBridge

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Utils

  @doc "Reports what the mounted volumes hold — file, folder, and principal counts."
  @impl true
  def channel_stats(config, params) when is_map(config) and is_map(params) do
    dispatch(:volume_stats, %{params: params}, config)
  end

  # -- files --

  @doc "Lists the documents on the mounted volumes as **unmaterialized** records — no content."
  @impl true
  def list_files(config, params) when is_map(config) and is_map(params) do
    dispatch(:list_records, %{params: params}, config)
  end

  @doc """
  Writes a file onto a volume and registers its document row.

  `path` is the destination directory and carries the volume; `name` is the file. Binary
  content travels base64-encoded under `encoding`. Ingestion owns which volumes are mounted,
  so it validates the destination rather than this bridge.
  """
  @impl true
  def create_file(config, params) when is_map(config) and is_map(params) do
    dispatch(:persist_record, persist_request(params), config)
  end

  @doc "Returns one document as an unmaterialized record — metadata only, no content."
  @impl true
  def get_file(config, params) when is_map(config) and is_map(params) do
    file_id = to_string(fetch(params, "file_id"))

    case dispatch(:describe_records, %{file_ids: [file_id]}, config) do
      # The id is re-checked rather than assumed. `describe_records` resolves exactly the ids
      # it was given, so this holds today — but it holds across a role boundary, and an
      # unchecked head would turn a future contract drift into the wrong file rather than a
      # `:not_found`.
      {:ok, %RecordPage{records: [%Record{id: ^file_id} = record | _]}} ->
        {:ok, %{record: record}}

      {:ok, %RecordPage{}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Rewrites, renames, or moves an existing document.

  Every field but `file_id` is optional: `name` renames, `path` moves to another directory,
  `content` (with `encoding` for binary) overwrites the bytes.
  """
  @impl true
  def update_file(config, params) when is_map(config) and is_map(params) do
    dispatch(:update_record, update_request(params), config)
  end

  @doc "Removes the document row and the file behind it, along with its chunks and sidecars."
  @impl true
  def delete_file(config, params) when is_map(config) and is_map(params) do
    dispatch(:delete_record, %{file_id: to_string(fetch(params, "file_id"))}, config)
  end

  @doc "Finds documents whose source or title matches `query`."
  @impl true
  def search_files(config, params) when is_map(config) and is_map(params) do
    dispatch(:search_records, %{params: params}, config)
  end

  @doc """
  Returns the document as an **unmaterialized** record: `content: nil` plus the
  `materializing_event` that fetches the bytes.

  Unlike a bridge fronting a system that holds the file, this one reads nothing. The bytes
  live on an ingestion volume, so carrying them back through here would route the whole
  payload across the channels node for no reason. A caller that actually wants the content
  dispatches `record.materializing_event`, which goes straight to ingestion.

  That makes this the same answer as `get_file/2` — the difference between the two is what
  the caller does with the record, not what this bridge reads.
  """
  @impl true
  def download_document(config, params) when is_map(config) and is_map(params) do
    get_file(config, params)
  end

  @doc "Lists who can read the given document — one record per person or team grant."
  @impl true
  def list_permissions(config, params) when is_map(config) and is_map(params) do
    dispatch(:list_record_permissions, %{file_id: to_string(fetch(params, "file_id"))}, config)
  end

  # -- requests --

  defp persist_request(params) do
    %{
      "name" => fetch(params, "name"),
      "path" => fetch(params, "path"),
      "content" => fetch(params, "content") || "",
      "encoding" => fetch(params, "encoding")
    }
  end

  # Only the keys the caller actually sent travel, so ingestion can tell "leave this alone"
  # from "set this to empty" — an absent `content` must not truncate the file.
  defp update_request(params) do
    ["name", "path", "content", "encoding"]
    |> Enum.reduce(%{"file_id" => to_string(fetch(params, "file_id"))}, fn key, request ->
      case fetch(params, key) do
        nil -> request
        value -> Map.put(request, key, value)
      end
    end)
  end

  # -- dispatch --

  # The bytes and the document rows live on the ingestion node, so every read crosses a role
  # boundary. The router is read off `config`, never off `params`: `params` is caller-supplied
  # data that reaches here verbatim from agent tools, and choosing the dispatch target from it
  # would make what runs a function of what the caller sent.
  defp dispatch(action, request, config) do
    node_router = fetch(config, "node_router") || NodeRouter

    request
    |> Event.new(:ingestion, opts: [action: action])
    |> node_router.dispatch()
    |> Map.fetch!(:response)
  end

  # Params arrive from agent tools with string keys and from internal callers with atom keys;
  # accept either rather than forcing every caller to normalise first.
  defp fetch(params, key), do: Utils.Map.present_value(params, key)
end
