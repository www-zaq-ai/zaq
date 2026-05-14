defmodule Zaq.Engine.Connect.OAuthTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{OAuth, OAuthState}

  setup do
    original_base_url = Application.get_env(:zaq, :connect_oauth_base_redirect_url)

    on_exit(fn ->
      if is_nil(original_base_url) do
        Application.delete_env(:zaq, :connect_oauth_base_redirect_url)
      else
        Application.put_env(:zaq, :connect_oauth_base_redirect_url, original_base_url)
      end
    end)

    :ok
  end

  defp create_credential!(attrs \\ %{}) do
    base = %{
      name: "oauth-cred-#{System.unique_integer([:positive])}",
      provider: "google_drive",
      auth_kind: "oauth2",
      request_format: "bearer",
      user_level: false,
      metadata: %{},
      client_id: "client-id",
      client_secret: "client-secret",
      scopes: ["scope.read"]
    }

    {:ok, credential} = Connect.create_credential(Map.merge(base, attrs))
    credential
  end

  test "build_authorize_url/2 rejects unsupported auth kind" do
    credential = create_credential!(%{auth_kind: "api_key"})

    assert {:error, :unsupported_auth_kind} = OAuth.build_authorize_url(credential, %{})
  end

  test "build_authorize_url/2 returns transport-level oauth error when provider is not configured" do
    credential = create_credential!()

    assert {:error, _reason} =
             OAuth.build_authorize_url(credential, %{"resource_type" => "data_source"})
  end

  test "finalize_callback/2 returns provider mismatch" do
    credential = create_credential!()

    state =
      OAuthState.sign(%{
        "credential_id" => credential.id,
        "provider" => "sharepoint"
      })

    assert {:error, :provider_mismatch} =
             OAuth.finalize_callback("google_drive", %{"state" => state, "code" => "oauth-code"})
  end

  test "finalize_callback/2 validates callback params" do
    assert {:error, :invalid_callback_params} =
             OAuth.finalize_callback("google_drive", %{"state" => "x"})
  end

  test "redirect_uri_for/1 uses configured base url" do
    Application.put_env(:zaq, :connect_oauth_base_redirect_url, "https://zaq.example")

    assert OAuth.redirect_uri_for("google_drive") ==
             "https://zaq.example/channels/oauth2/google_drive/redirect"
  end
end
