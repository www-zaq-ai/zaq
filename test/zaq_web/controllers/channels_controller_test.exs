defmodule ZaqWeb.ChannelsControllerTest do
  use ZaqWeb.ConnCase, async: true

  setup do
    previous = Application.get_env(:zaq, :connect_oauth_module)
    on_exit(fn -> Application.put_env(:zaq, :connect_oauth_module, previous) end)
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

  defmodule SuccessOAuth do
    def finalize_callback(_provider, _params), do: {:ok, %{id: 7}}
  end

  defmodule ErrorOAuth do
    def finalize_callback(_provider, _params), do: {:error, :invalid_callback_params}
  end
end
