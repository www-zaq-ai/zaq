defmodule ZaqWeb.PersonConversationResourceController do
  @moduledoc "Serves parent-scoped People conversation resources through confidential Engine operations."
  use ZaqWeb, :controller
  alias Zaq.{Config, NodeRouter}
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Events
  alias Zaq.Materialization
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

  defp send_resource(
         conn,
         :source,
         %{materialization_handle: handle, actor: actor} = resource,
         router
       ) do
    with {:ok, %{record: %Record{} = record}} <-
           Materialization.materialize(
             handle,
             %{actor: actor, node_router: router},
             "Source unavailable"
           ),
         {:ok, bytes} <- decode(record) do
      PrivateResourceResponse.send(conn, %{
        content: bytes,
        name: record.name || resource.name,
        mime_type: record.mime_type || resource.mime_type
      })
    else
      _ -> conn |> put_status(:not_found) |> text("Resource not found")
    end
  end

  defp send_resource(conn, _op, resource, _router),
    do: PrivateResourceResponse.send(conn, resource)

  defp decode(%Record{content: content, attributes: %{"encoding" => "base64"}})
       when is_binary(content), do: Base.decode64(content)

  defp decode(%Record{content: content}) when is_binary(content), do: {:ok, content}
  defp decode(_), do: {:error, :not_found}
end
