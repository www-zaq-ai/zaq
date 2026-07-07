defmodule Zaq.Channels.JidoChatBridge.Media do
  @moduledoc """
  Builds stub `%Record{}` structs from `Jido.Chat.Media` items from incoming message.
  """
  alias Jido.Chat.Media
  alias Zaq.Contracts.Record

  @spec build_records([Media.t()], atom(), map()) :: [Record.t()]
  def build_records(media, provider, _config) do
    records =
      (media || [])
      |> Media.normalize_many()
      |> Enum.map(fn m ->
        %Record{
          id: record_id(m, provider),
          kind: :file,
          content: nil,
          name: m.filename,
          mime_type: m.media_type,
          size: m.size_bytes,
          url: m.url,
          attributes: %{"source" => "channel_attachment"}
        }
      end)

    records
  end

  defp record_id(media, provider) do
    file_id = media.metadata[:file_id] || media.url
    "#{provider}_#{file_id}"
  end
end
