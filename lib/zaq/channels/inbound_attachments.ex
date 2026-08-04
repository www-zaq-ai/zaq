defmodule Zaq.Channels.InboundAttachments do
  @moduledoc """
  Persists media sent through a communication channel onto an ingestion volume.

  An inbound attachment arrives as an **unmaterialized** record whose `materializing_event`
  reaches the provider that holds the bytes. This module runs that event and writes the
  result to a volume through `Zaq.Channels.DiskBridge`, answering with a record that is
  unmaterialized again — now backed by a `documents.id` rather than a provider reference.

  Both hops run on the channels node deliberately. The bytes are fetched here and handed
  straight to ingestion, so they cross a node boundary once instead of travelling back
  through the caller that asked for the write.

  The destination volume is channel configuration (`settings["attachments"]["volume"]`).
  Until a channel names one, the first mounted volume is used so an upgrade does not start
  dropping files. Within it, files are laid out by owner then channel:

      <volume>/attachments/jad-tarabay-84/telegram/logo.png
      <volume>/attachments/person-84/telegram/logo.png          # resolved, but unnamed
      <volume>/attachments/anonymous-366923529/telegram/logo.png

  Two files sent with the same name on the same channel resolve to the same path, so the
  later one replaces the earlier — the record is the message's attachment, not a version
  history of it.
  """

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.DiskBridge
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc """
  Fetches an attachment's bytes and stores them on a volume.

  Expects `:record` plus the identity the storage path is built from. Returns
  `{:ok, %{record: record}}` with the disk-backed record, or `{:error, reason}` when the
  provider fetch or the volume write fails.
  """
  @spec persist(map()) :: {:ok, map()} | {:error, term()}
  def persist(%{record: %Record{} = record} = request) do
    with {:ok, content, encoding} <- materialize(record, request),
         {:ok, volume} <- destination_volume(request) do
      write(record, content, encoding, volume, request)
    end
  end

  def persist(_request), do: {:error, :record_required}

  # The record names its own way of being materialized; running that event rather than
  # calling a provider directly is what keeps this module free of provider knowledge.
  defp materialize(%Record{content: content, attributes: attributes}, _request)
       when is_binary(content),
       do: {:ok, content, Map.get(attributes || %{}, "encoding")}

  defp materialize(%Record{materializing_event: %Event{} = event}, request) do
    node_router = Map.get(request, :node_router, NodeRouter)

    case event |> node_router.dispatch() |> Map.fetch!(:response) do
      {:ok, %{record: %Record{content: content, attributes: attributes}}}
      when is_binary(content) ->
        {:ok, content, Map.get(attributes || %{}, "encoding")}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_materialize_response, other}}
    end
  end

  defp materialize(%Record{}, _request), do: {:error, :not_materializable}

  defp write(%Record{} = record, content, encoding, volume, request) do
    params = %{
      "name" => file_name(record),
      "path" =>
        Path.join([volume, "attachments", owner_segment(request), channel_segment(request)]),
      "content" => content,
      "encoding" => encoding
    }

    case DiskBridge.create_file(disk_config(request), params) do
      {:ok, %{record: %Record{} = stored}} -> {:ok, %{record: stored}}
      {:ok, other} -> {:error, {:unexpected_persist_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A resolved person owns the file, named so the trail is readable rather than a bare id.
  # The id stays as a suffix because names are neither unique nor stable: two people called
  # Jad Tarabay would otherwise share a folder and overwrite each other's files.
  defp owner_segment(%{person_id: person_id} = request) when not is_nil(person_id) do
    case request |> Map.get(:person_name) |> slug() do
      nil -> "person-#{person_id}"
      name -> "#{name}-#{person_id}"
    end
  end

  # Without a resolved person the message still has an author, so the trail stays
  # attributable rather than collapsing every unknown sender into one folder.
  defp owner_segment(request) do
    case Map.get(request, :author_id) do
      author when is_binary(author) and author != "" -> "anonymous-#{author}"
      author when is_integer(author) -> "anonymous-#{author}"
      _ -> "anonymous"
    end
  end

  # A person's name is user-controlled text on its way into a filesystem path, so it is
  # reduced to an ASCII slug rather than trusted: separators, traversal, and unicode all
  # collapse to hyphens. An empty result means there was no usable name.
  defp slug(name) when is_binary(name) do
    name
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^\x00-\x7F]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> nil
      slug -> String.slice(slug, 0, 64)
    end
  end

  defp slug(_name), do: nil

  # The channel the file arrived on. It sits below the owner rather than above it so one
  # person's attachments stay in one place regardless of how many channels they use.
  defp channel_segment(request) do
    case request |> Map.get(:provider) |> to_string() do
      "" -> "unknown"
      provider -> provider
    end
  end

  defp file_name(%Record{name: name, id: id}) do
    case name do
      name when is_binary(name) and name != "" -> Path.basename(name)
      _ -> Path.basename(to_string(id))
    end
  end

  defp destination_volume(request) do
    case configured_volume(request) do
      volume when is_binary(volume) and volume != "" -> {:ok, volume}
      _ -> first_volume(request)
    end
  end

  defp configured_volume(request) do
    with provider when not is_nil(provider) <- Map.get(request, :provider),
         %ChannelConfig{settings: settings} <-
           ChannelConfig.get_by_provider(to_string(provider)) do
      get_in(settings || %{}, ["attachments", "volume"])
    else
      _ -> nil
    end
  end

  defp first_volume(request) do
    node_router = Map.get(request, :node_router, NodeRouter)

    case %{} |> Event.new(:ingestion, opts: [action: :list_volumes]) |> node_router.dispatch() do
      %Event{response: {:ok, volumes}} when map_size(volumes) > 0 ->
        {:ok, volumes |> Map.keys() |> Enum.sort() |> List.first()}

      _ ->
        {:error, :no_volume_configured}
    end
  end

  defp disk_config(request) do
    case Map.get(request, :node_router) do
      nil -> %{}
      node_router -> %{"node_router" => node_router}
    end
  end
end
