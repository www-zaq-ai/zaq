defmodule ZaqWeb.MessageTraceArtifactController do
  @moduledoc "Serves authenticated BO trace artifacts through the Engine boundary."

  use ZaqWeb, :controller

  alias Zaq.Config
  alias Zaq.Event
  alias Zaq.NodeRouter

  @inline_types ~w[image/png image/jpeg image/gif image/webp application/pdf text/plain]

  def show(conn, %{"id" => artifact_id}) do
    event =
      Event.new(artifact_id, :engine,
        actor: %{user_id: conn.assigns.current_user.id},
        opts: [action: :get_message_trace_artifact]
      )

    case node_router_module(conn).dispatch(event).response do
      {:ok, artifact} -> serve_artifact(conn, artifact)
      {:error, :unauthorized} -> conn |> put_status(:forbidden) |> text("Forbidden")
      {:error, :not_found} -> conn |> put_status(:not_found) |> text("Artifact not found")
      _ -> conn |> put_status(:internal_server_error) |> text("Could not read artifact")
    end
  end

  defp serve_artifact(conn, artifact) do
    content_type = safe_content_type(artifact.mime_type)
    disposition = if content_type in @inline_types, do: "inline", else: "attachment"
    filename = safe_filename(artifact.name)

    conn
    |> put_resp_content_type(content_type, nil)
    |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{filename}"))
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "sandbox")
    |> send_resp(:ok, artifact.content)
  end

  defp safe_content_type(mime_type) when mime_type in @inline_types, do: mime_type
  defp safe_content_type(_mime_type), do: "application/octet-stream"

  defp safe_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1F\x7F"\\]+/u, "_")
    |> case do
      "" -> "artifact"
      sanitized -> sanitized
    end
  end

  defp safe_filename(_name), do: "artifact"

  defp node_router_module(conn) do
    Config.get(:zaq, :message_trace_artifact_controller_node_router_module, NodeRouter,
      config: conn.assigns[:config]
    )
  end
end
