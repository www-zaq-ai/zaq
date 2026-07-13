defmodule ZaqWeb.ChannelsController do
  use ZaqWeb, :controller

  alias Zaq.Engine.Connect.OAuth
  alias Zaq.Event
  alias Zaq.NodeRouter

  def health(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def oauth2_redirect(conn, %{"provider" => provider} = params) do
    case dispatch_engine_invoke(oauth_module(), :finalize_callback, [provider, params]) do
      {:ok, grant} ->
        html(
          conn,
          oauth_result_html("success", "Grant created", %{grant_id: grant.id, provider: provider})
        )

      {:error, reason} ->
        html(
          conn,
          oauth_result_html("error", "Grant failed", %{
            provider: provider,
            reason: inspect(reason)
          })
        )
    end
  end

  def openai_oauth_callback(conn, params) do
    oauth2_redirect(conn, Map.put(params, "provider", "openai"))
  end

  def webhook(conn, %{"type" => type, "provider" => provider} = params)
      when type in ["conversation", "data_source"] do
    payload = request_payload(conn, params)

    event =
      Event.new(
        %{type: type, provider: provider, payload: payload},
        :channels,
        opts: [action: :webhook_delivered]
      )

    case node_router_module().dispatch(event).response do
      {:ok, %{webhook_response: webhook_response} = result} when type == "conversation" ->
        maybe_passthrough_webhook_response(conn, webhook_response, result)

      {:ok, result} ->
        json(conn, %{status: "accepted", result: result})

      :ok ->
        json(conn, %{status: "accepted"})

      {:error, reason} ->
        json(conn, %{status: "rejected", reason: inspect(reason)})

      other ->
        json(conn, %{status: "accepted", result: other})
    end
  end

  def webhook(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid webhook type"})
  end

  defp oauth_module, do: Application.get_env(:zaq, :connect_oauth_module, OAuth)

  defp node_router_module,
    do: Application.get_env(:zaq, :channels_controller_node_router_module, NodeRouter)

  defp dispatch_engine_invoke(mod, fun, args)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    event =
      Event.new(
        %{module: mod, function: fun, args: args},
        :engine,
        opts: [action: :invoke]
      )

    node_router_module().dispatch(event).response
  end

  defp oauth_result_html(status, message, payload) do
    encoded = Jason.encode!(Map.put(payload, :status, status))

    """
    <!doctype html>
    <html>
      <head>
        <meta charset=\"utf-8\" />
        <title>OAuth Callback</title>
      </head>
      <body>
        <p>#{message}</p>
        <script>
          (function () {
            var payload = #{encoded};
            if (window.opener && !window.opener.closed) {
              window.opener.postMessage({type: "zaq:oauth2_result", payload: payload}, "*");
              window.close();
            }

            if (window.parent && window.parent !== window) {
              window.parent.postMessage({type: "zaq:oauth2_result", payload: payload}, "*");
            }
          })();
        </script>
      </body>
    </html>
    """
  end

  defp maybe_passthrough_webhook_response(conn, %{status: status} = webhook_response, _result)
       when is_integer(status) do
    conn =
      Enum.reduce(Map.get(webhook_response, :headers, %{}), conn, fn {key, value}, acc ->
        normalized_key = String.downcase(to_string(key))

        if normalized_key in ["content-length", "transfer-encoding"] do
          acc
        else
          put_resp_header(acc, normalized_key, to_string(value))
        end
      end)

    body = Map.get(webhook_response, :body)

    cond do
      is_binary(body) -> send_resp(conn, status, body)
      is_nil(body) -> send_resp(conn, status, "")
      true -> conn |> put_status(status) |> json(body)
    end
  end

  defp maybe_passthrough_webhook_response(conn, _webhook_response, result),
    do: json(conn, %{status: "accepted", result: result})

  defp request_payload(conn, params) do
    body_payload = Map.drop(params, ["type", "provider"])

    %{
      "method" => conn.method,
      "path" => conn.request_path,
      "headers" => Map.new(conn.req_headers),
      "query" => conn.query_params,
      "payload" => body_payload,
      "raw" => Map.get(conn.assigns, :raw_body)
    }
  end
end
