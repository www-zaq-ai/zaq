defmodule ZaqWeb.ChannelsControllerTest do
  use ZaqWeb.ConnCase, async: true

  setup do
    previous = Application.get_env(:zaq, :connect_oauth_module)
    previous_router = Application.get_env(:zaq, :channels_controller_node_router_module)
    on_exit(fn -> Application.put_env(:zaq, :connect_oauth_module, previous) end)

    on_exit(fn ->
      if previous_router do
        Application.put_env(:zaq, :channels_controller_node_router_module, previous_router)
      else
        Application.delete_env(:zaq, :channels_controller_node_router_module)
      end
    end)

    :ok
  end

  test "oauth2 redirect renders success auto-close page", %{conn: conn} do
    Application.put_env(:zaq, :connect_oauth_module, __MODULE__.SuccessOAuth)

    conn =
      get(conn, "/channels/oauth2/google_drive/redirect", %{"state" => "ok", "code" => "123"})

    assert html_response(conn, 200) =~ "Grant created"
    assert html_response(conn, 200) =~ "window.opener.postMessage"
  end

  test "oauth2 redirect renders error page", %{conn: conn} do
    Application.put_env(:zaq, :connect_oauth_module, __MODULE__.ErrorOAuth)

    conn = get(conn, "/channels/oauth2/google_drive/redirect", %{"state" => "bad"})

    assert html_response(conn, 200) =~ "Grant failed"
  end

  test "localhost auth callback finalizes OpenAI OAuth", %{conn: conn} do
    Application.put_env(:zaq, :connect_oauth_module, __MODULE__.RecordingOAuth)

    conn = get(conn, "/auth/callback", %{"state" => "ok", "code" => "123"})

    assert html_response(conn, 200) =~ "Grant created"
    assert_received {:finalize_callback, "openai", %{"state" => "ok", "code" => "123"}}
  end

  test "webhook forwards data_source payload to channels API action", %{conn: conn} do
    Application.put_env(:zaq, :channels_controller_node_router_module, __MODULE__.WebhookRouter)

    conn =
      post(conn, "/channels/webhook/data_source/google_drive", %{
        "event" => "file.changed",
        "id" => "evt-1"
      })

    assert json_response(conn, 200)["status"] == "accepted"

    assert_received {:webhook_event,
                     %{type: "data_source", provider: "google_drive", payload: payload},
                     :webhook_delivered}

    assert payload["payload"]["event"] == "file.changed"
  end

  test "webhook conversation passes through adapter webhook response", %{conn: conn} do
    Application.put_env(:zaq, :channels_controller_node_router_module, __MODULE__.WebhookRouter)

    conn =
      post(conn, "/channels/webhook/conversation/telegram", %{
        "event" => "message",
        "challenge" => "abc"
      })

    assert response(conn, 202) == "verified"
    assert get_resp_header(conn, "x-webhook-provider") == ["telegram"]
  end

  test "webhook rejects invalid type", %{conn: conn} do
    conn = post(conn, "/channels/webhook/nope/google_drive", %{"event" => "x"})
    assert json_response(conn, 400)["error"] == "Invalid webhook type"
  end

  test "webhook data_source returns accepted with result when dispatch returns {:ok, result}", %{
    conn: conn
  } do
    Application.put_env(:zaq, :channels_controller_node_router_module, __MODULE__.OkResultRouter)

    conn =
      post(conn, "/channels/webhook/data_source/google_drive", %{
        "event" => "file.changed",
        "id" => "evt-1"
      })

    assert json_response(conn, 200)["status"] == "accepted"
    assert json_response(conn, 200)["result"] == %{"processed" => true}
  end

  test "webhook returns rejected status on dispatch error", %{conn: conn} do
    Application.put_env(:zaq, :channels_controller_node_router_module, __MODULE__.ErrorRouter)

    conn =
      post(conn, "/channels/webhook/data_source/google_drive", %{
        "event" => "file.changed"
      })

    assert json_response(conn, 200)["status"] == "rejected"
    assert json_response(conn, 200)["reason"] =~ "unauthorized"
  end

  test "webhook handles unexpected response format gracefully", %{conn: conn} do
    Application.put_env(
      :zaq,
      :channels_controller_node_router_module,
      __MODULE__.UnexpectedResponseRouter
    )

    conn =
      post(conn, "/channels/webhook/data_source/google_drive", %{
        "event" => "file.changed"
      })

    assert json_response(conn, 200)["status"] =~ "accepted"
    assert json_response(conn, 200)["result"] == "unexpected"
  end

  test "webhook conversation filters content-length and transfer-encoding headers", %{conn: conn} do
    Application.put_env(
      :zaq,
      :channels_controller_node_router_module,
      __MODULE__.FilteredHeadersRouter
    )

    conn =
      post(conn, "/channels/webhook/conversation/telegram", %{
        "event" => "message"
      })

    assert response(conn, 200) == "ok"

    assert get_resp_header(conn, "content-length") == []
    assert get_resp_header(conn, "transfer-encoding") == []
    assert get_resp_header(conn, "x-custom-header") == ["present"]
  end

  test "webhook conversation with nil body returns empty response", %{conn: conn} do
    Application.put_env(:zaq, :channels_controller_node_router_module, __MODULE__.NilBodyRouter)

    conn =
      post(conn, "/channels/webhook/conversation/telegram", %{
        "event" => "message"
      })

    assert response(conn, 204) == ""
  end

  test "webhook conversation with map body returns json response", %{conn: conn} do
    Application.put_env(:zaq, :channels_controller_node_router_module, __MODULE__.MapBodyRouter)

    conn =
      post(conn, "/channels/webhook/conversation/telegram", %{
        "event" => "message"
      })

    assert json_response(conn, 200) == %{"message" => "hello"}
  end

  test "webhook conversation without integer status falls back to generic accepted response", %{
    conn: conn
  } do
    Application.put_env(:zaq, :channels_controller_node_router_module, __MODULE__.NoStatusRouter)

    conn =
      post(conn, "/channels/webhook/conversation/telegram", %{
        "event" => "message"
      })

    assert json_response(conn, 200)["status"] == "accepted"
    assert json_response(conn, 200)["result"]["webhook_response"]["status"] == "ok"
  end

  defmodule SuccessOAuth do
    def finalize_callback(_provider, _params), do: {:ok, %{id: 7}}
  end

  defmodule ErrorOAuth do
    def finalize_callback(_provider, _params), do: {:error, :invalid_callback_params}
  end

  defmodule RecordingOAuth do
    def finalize_callback(provider, params) do
      send(self(), {:finalize_callback, provider, params})
      {:ok, %{id: 8}}
    end
  end

  defmodule WebhookRouter do
    def dispatch(event) do
      send(self(), {:webhook_event, event.request, Keyword.fetch!(event.opts, :action)})

      response =
        case event.request do
          %{type: "conversation", provider: provider} ->
            {:ok,
             %{
               webhook_response: %{
                 status: 202,
                 headers: %{"x-webhook-provider" => provider},
                 body: "verified"
               }
             }}

          _ ->
            :ok
        end

      %{event | response: response}
    end
  end

  defmodule OkResultRouter do
    def dispatch(event) do
      %{event | response: {:ok, %{processed: true}}}
    end
  end

  defmodule ErrorRouter do
    def dispatch(event) do
      %{event | response: {:error, :unauthorized}}
    end
  end

  defmodule UnexpectedResponseRouter do
    def dispatch(event) do
      %{event | response: "unexpected"}
    end
  end

  defmodule FilteredHeadersRouter do
    def dispatch(event) do
      response =
        {:ok,
         %{
           webhook_response: %{
             status: 200,
             headers: %{
               "content-length" => "100",
               "transfer-encoding" => "chunked",
               "x-custom-header" => "present"
             },
             body: "ok"
           }
         }}

      %{event | response: response}
    end
  end

  defmodule NilBodyRouter do
    def dispatch(event) do
      response =
        {:ok,
         %{
           webhook_response: %{
             status: 204,
             headers: %{},
             body: nil
           }
         }}

      %{event | response: response}
    end
  end

  defmodule MapBodyRouter do
    def dispatch(event) do
      response =
        {:ok,
         %{
           webhook_response: %{
             status: 200,
             headers: %{"content-type" => "application/json"},
             body: %{"message" => "hello"}
           }
         }}

      %{event | response: response}
    end
  end

  defmodule NoStatusRouter do
    def dispatch(event) do
      response =
        {:ok,
         %{
           webhook_response: %{
             status: "ok",
             body: "test"
           },
           extra_data: "present"
         }}

      %{event | response: response}
    end
  end
end
