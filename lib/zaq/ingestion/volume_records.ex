defmodule Zaq.Ingestion.VolumeRecords do
  @moduledoc """
  Converts resolved volume entries into canonical `Zaq.Contracts.Record` values.

  Identity and path resolution live in `Zaq.Ingestion.VolumeEntries`; this module only puts
  the `Zaq.Contracts.Record` shape on top of what that returns.

  Producing records is the data-source bridge's concern, not ingestion's — the remaining
  callers here are the ingest pipeline, which takes records as input, and BO's
  `Zaq.Ingestion.directory_snapshot/3`, which is moving to `Zaq.Channels.DiskBridge`.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion.FileExplorer.Entry
  alias Zaq.Ingestion.VolumeEntries

  @doc "Resolves local volume entries and converts them into canonical records."
  @spec from_entries([Entry.t()]) :: [Record.t()]
  def from_entries(entries) when is_list(entries) do
    entries
    |> VolumeEntries.resolve()
    |> Enum.map(&to_record/1)
  end

  @doc "Builds a canonical record for a path inside a local volume."
  @spec from_path(String.t() | nil, String.t()) :: {:ok, Record.t()} | {:error, term()}
  def from_path(volume_name, path) do
    with {:ok, %Entry{} = entry} <- VolumeEntries.from_path(volume_name, path) do
      {:ok, to_record(entry)}
    end
  end

  @doc "Converts one resolved volume entry into a canonical record."
  @spec to_record(Entry.t()) :: Record.t()
  def to_record(%Entry{} = entry) do
    kind = kind(entry.type)

    %Record{
      id: entry.id,
      kind: kind,
      name: entry.name,
      path: entry.relative_path,
      mime_type: mime_type(kind, entry.name),
      materializing_event: materializing_event(kind, entry.id),
      size: entry.size,
      modified_at: entry.modified_at,
      attributes: %{
        "provider" => VolumeEntries.local_provider(),
        "volume" => entry.volume,
        "relative_path" => entry.relative_path,
        "source" => entry.source
      },
      raw: %{local_entry: entry}
    }
  end

  defp kind(:directory), do: :folder
  defp kind(_type), do: :file

  # A volume entry carries no declared type, so the extension is all there is to go on.
  defp mime_type(:file, name), do: MIME.from_path(name)
  defp mime_type(_kind, _name), do: nil

  # A record travels without its bytes — reading every file a listing names would be wasted
  # work. This is the hop that fetches them when a caller actually wants the content. A
  # folder has nothing to materialize.
  defp materializing_event(:file, id),
    do: Event.new(%{file_id: id}, :ingestion, opts: [action: :materialize_record])

  defp materializing_event(_kind, _id), do: nil
end
