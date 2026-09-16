defmodule ZaqWeb.PersonConversationResourceController do
  @moduledoc "Serves parent-scoped People conversation resources through confidential Engine operations."
  use ZaqWeb, :controller
  alias Zaq.Config
  alias Zaq.Engine.Events
  alias Zaq.NodeRouter
  alias ZaqWeb.PersonConversationResource
  alias ZaqWeb.PrivateResourceResponse

  def show(conn, params) do
    op = if params["artifact_id"], do: :artifact, else: :source

    request = %{
      op: op,
      token: get_session(conn, :person_session_token),
      conversation_id: params["id"],
      message_id: params["message_id"],
      artifact_id: params["artifact_id"],
      source: params["source"]
    }

    node_router =
      Config.get(:zaq, :person_conversation_resource_node_router_module, NodeRouter,
        config: conn.assigns[:config]
      )

    case Events.build_and_dispatch_invoke_event(request, :people_conversations,
           event_opts: [confidential: true],
           node_router: node_router
         ).response do
      {:ok, resource} -> send_resource(conn, op, resource, node_router)
      {:error, :invalid_session} -> redirect(conn, to: "/people/login")
      _ -> conn |> put_status(:not_found) |> text("Resource not found")
    end
  rescue
    _ -> conn |> put_status(:not_found) |> text("Resource not found")
  catch
    :exit, _ -> conn |> put_status(:not_found) |> text("Resource not found")
  end

  defp send_resource(conn, op, resource, router) do
    case PersonConversationResource.load(op, resource, router) do
      {:ok, resource} -> PrivateResourceResponse.send(conn, resource)
      _ -> conn |> put_status(:not_found) |> text("Resource not found")
    end
  end
end
