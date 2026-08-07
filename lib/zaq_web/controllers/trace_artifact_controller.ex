defmodule ZaqWeb.TraceArtifactController do
  @moduledoc """
  Serves the bytes an agent read during a turn, for reviewing a message trace.

  The trace entry carries only a pointer and the metadata a file chip needs, so the bytes move
  when a reviewer asks for them rather than on every conversation render. `bytea` reads back as
  a binary, so nothing is re-encoded on the way out.

  An artifact stored as metadata only — one over the size cap — has no bytes to send and
  answers 404 rather than an empty file.
  """

  use ZaqWeb, :controller

  alias Zaq.Engine.Conversations.MessageTraceArtifact
  alias Zaq.Event
  alias Zaq.NodeRouter

  def show(conn, %{"id" => id}) do
    case fetch(id) do
      # `send_download` otherwise derives the type from the file name's extension, which is the
      # provider's guess rather than what the bytes were sniffed as.
      %MessageTraceArtifact{content: content} = artifact when is_binary(content) ->
        send_download(conn, {:binary, content},
          filename: filename(artifact),
          content_type: artifact.mime_type || "application/octet-stream",
          disposition: :inline
        )

      _missing_or_metadata_only ->
        conn |> put_status(:not_found) |> text("Not found")
    end
  end

  defp fetch(id) do
    %{id: id}
    |> Event.new(:engine, opts: [action: :get_trace_artifact])
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
    |> case do
      {:ok, %MessageTraceArtifact{} = artifact} -> artifact
      _other -> nil
    end
  end

  # A provider that named nothing still has to download as something.
  defp filename(%MessageTraceArtifact{name: name}) when is_binary(name) and name != "", do: name
  defp filename(%MessageTraceArtifact{id: id}), do: "attachment-#{id}"
end
