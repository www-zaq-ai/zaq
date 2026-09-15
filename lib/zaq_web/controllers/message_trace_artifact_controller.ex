defmodule ZaqWeb.MessageTraceArtifactController do
  @moduledoc "Serves authenticated BO trace artifacts through the Engine boundary."

  use ZaqWeb, :controller

  alias Zaq.Config
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias ZaqWeb.PrivateResourceResponse

  def show(conn, %{"id" => artifact_id}) do
    event =
      Event.new(artifact_id, :engine,
        actor: %{user_id: conn.assigns.current_user.id},
        opts: [action: :get_message_trace_artifact]
      )

    case node_router_module(conn).dispatch(event).response do
      {:ok, artifact} -> PrivateResourceResponse.send(conn, artifact)
      {:error, :unauthorized} -> conn |> put_status(:forbidden) |> text("Forbidden")
      {:error, :not_found} -> conn |> put_status(:not_found) |> text("Artifact not found")
      _ -> conn |> put_status(:internal_server_error) |> text("Could not read artifact")
    end
  end

  defp node_router_module(conn) do
    Config.get(:zaq, :message_trace_artifact_controller_node_router_module, NodeRouter,
      config: conn.assigns[:config]
    )
  end
end
