defmodule ZaqWeb.EndpointChatAuthTest do
  use ZaqWeb.ConnCase, async: false

  @token "endpoint-chat-token"

  defmodule ReadTrackingAdapter do
    def read_req_body({owner, adapter, state}, opts) do
      send(owner, :request_body_read)

      case adapter.read_req_body(state, opts) do
        {status, body, next_state} -> {status, body, {owner, adapter, next_state}}
      end
    end

    def send_resp({owner, adapter, state}, status, headers, body) do
      {:ok, response, next_state} = adapter.send_resp(state, status, headers, body)
      {:ok, response, {owner, adapter, next_state}}
    end

    def get_peer_data({_owner, adapter, state}), do: adapter.get_peer_data(state)
    def get_sock_data({_owner, adapter, state}), do: adapter.get_sock_data(state)
    def get_ssl_data({_owner, adapter, state}), do: adapter.get_ssl_data(state)
    def get_http_protocol({_owner, adapter, state}), do: adapter.get_http_protocol(state)
  end

  setup do
    previous_token = System.get_env("ZAQ_CHAT_TOKEN")
    System.put_env("ZAQ_CHAT_TOKEN", @token)

    on_exit(fn -> restore_env("ZAQ_CHAT_TOKEN", previous_token) end)

    :ok
  end

  test "AUTH-4: a missing bearer is rejected before the request body is read" do
    conn = call_endpoint(tracked_json_conn(%{"messages" => []}))

    assert json_response(conn, 401)["error"]["message"] == "missing bearer token"
    refute_received :request_body_read
  end

  test "AUTH-4: an invalid bearer is rejected before the request body is read" do
    conn =
      %{"messages" => []}
      |> tracked_json_conn()
      |> put_req_header("authorization", "Bearer wrong-token")
      |> call_endpoint()

    assert json_response(conn, 401)["error"]["message"] == "invalid bearer token"
    refute_received :request_body_read
  end

  defp tracked_json_conn(body) do
    conn =
      :post
      |> Plug.Test.conn("/v1/chat/completions", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    {adapter, state} = conn.adapter
    %{conn | adapter: {ReadTrackingAdapter, {self(), adapter, state}}}
  end

  defp call_endpoint(conn), do: ZaqWeb.Endpoint.call(conn, ZaqWeb.Endpoint.init([]))

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
