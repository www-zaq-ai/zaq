defmodule Zaq.Agent.Tools.Conversations.DownloadAttachment do
  @moduledoc """
  Tool for downloading a chat channel attachment by file_id.
  """
  use Zaq.Engine.Workflows.Action,
    name: "download_chat_attachment",
    description: "Download a file attachment from a chat channel by its file identifier.",
    schema: [
      provider: [
        type: :string,
        required: true,
        doc: "Chat provider key (e.g., mattermost, telegram)"
      ],
      file_id: [
        type: :string,
        required: true,
        doc: "Platform file identifier — from the attachment's `url` field in incoming.records"
      ],
      record_id: [
        type: :string,
        required: false,
        doc: "Optional identifier to assign to the resulting MaterializedRecord"
      ]
    ],
    output_schema: [
      materialized_record: [
        type: {:struct, Zaq.Contracts.MaterializedRecord},
        required: false,
        doc: "Downloaded file content and metadata"
      ]
    ]

  alias Zaq.Agent.Tools.Error
  alias Zaq.Event

  @impl Jido.Action
  def run(params, context) do
    node_router = Map.get(context, :node_router, Zaq.NodeRouter)

    request = %{
      provider: params.provider,
      file_id: params.file_id,
      record_id: Map.get(params, :record_id)
    }

    event = Event.new(request, :channels, opts: [action: :download_chat_attachment])

    case node_router.dispatch(event) |> Map.get(:response) do
      {:ok, %{materialized_record: record}} ->
        {:ok, %{materialized_record: record}}

      {:error, reason} ->
        {:error, "Download failed: #{Error.format(reason)}"}

      other ->
        {:error, "Download failed: unexpected response #{inspect(other)}"}
    end
  end
end
