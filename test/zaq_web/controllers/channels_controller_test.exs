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

    assert payload["params"]["event"] == "file.changed"
  end

  test "webhook rejects invalid type", %{conn: conn} do
    conn = post(conn, "/channels/webhook/nope/google_drive", %{"event" => "x"})
    assert json_response(conn, 400)["error"] == "Invalid webhook type"
  end

  defmodule SuccessOAuth do
    def finalize_callback(_provider, _params), do: {:ok, %{id: 7}}
  end

  defmodule ErrorOAuth do
    def finalize_callback(_provider, _params), do: {:error, :invalid_callback_params}
  end

  defmodule WebhookRouter do
    def dispatch(event) do
      send(self(), {:webhook_event, event.request, Keyword.fetch!(event.opts, :action)})
      %{event | response: :ok}
    end
  end
end
