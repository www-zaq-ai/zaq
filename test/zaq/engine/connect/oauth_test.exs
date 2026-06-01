defmodule Zaq.Engine.Connect.OAuthTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{OAuth, OAuthState}
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias Zaq.System, as: ZaqSystem
  alias Zaq.Types.EncryptedString

  defmodule TestOAuthBridge do
    def auth_handshake(_config, _params), do: {:error, :unsupported}
    def list_resources(_config, _params), do: {:error, :unsupported}
    def download_resource(_config, _resource, _params), do: {:error, :unsupported}
    def setup_listener(_config, _params), do: {:error, :unsupported}
    def teardown_listener(_config, _params), do: {:error, :unsupported}
    def list_files(_config, _params), do: {:error, :unsupported}
    def list_permissions(_config, _params), do: {:error, :unsupported}
    def channel_stats(_config, _params), do: {:error, :unsupported}
    def capability_snapshot(_config), do: {:error, :unsupported}

    def oauth_authorize_url(_config, _params), do: {:ok, "https://oauth.example/authorize"}

    def oauth_exchange_code(_config, _params) do
      {:ok,
       %{
         access_token: "access-token",
         refresh_token: "refresh-token",
         expires_at: DateTime.add(DateTime.utc_now(), 1800, :second),
         scopes: ["scope.read"]
       }}
    end

    def oauth_refresh_token(_config, _params), do: {:error, :unsupported}
  end

  defmodule InvalidOAuthBridge do
    def auth_handshake(_config, _params), do: {:error, :unsupported}
    def list_resources(_config, _params), do: {:error, :unsupported}
    def download_resource(_config, _resource, _params), do: {:error, :unsupported}
    def setup_listener(_config, _params), do: {:error, :unsupported}
    def teardown_listener(_config, _params), do: {:error, :unsupported}
    def list_files(_config, _params), do: {:error, :unsupported}
    def list_permissions(_config, _params), do: {:error, :unsupported}
    def channel_stats(_config, _params), do: {:error, :unsupported}
    def capability_snapshot(_config), do: {:error, :unsupported}

    def oauth_authorize_url(_config, _params), do: :invalid
    def oauth_exchange_code(_config, _params), do: :invalid
    def oauth_refresh_token(_config, _params), do: {:error, :unsupported}
  end

  defmodule StringKeyOAuthBridge do
    def auth_handshake(_config, _params), do: {:error, :unsupported}
    def list_resources(_config, _params), do: {:error, :unsupported}
    def download_resource(_config, _resource, _params), do: {:error, :unsupported}
    def setup_listener(_config, _params), do: {:error, :unsupported}
    def teardown_listener(_config, _params), do: {:error, :unsupported}
    def list_files(_config, _params), do: {:error, :unsupported}
    def list_permissions(_config, _params), do: {:error, :unsupported}
    def channel_stats(_config, _params), do: {:error, :unsupported}
    def capability_snapshot(_config), do: {:error, :unsupported}

    def oauth_authorize_url(_config, _params), do: {:ok, "https://oauth.example/authorize"}

    def oauth_exchange_code(_config, _params) do
      {:ok,
       %{
         "access_token" => "string-access-token",
         "refresh_token" => "string-refresh-token",
         "expires_at" => DateTime.add(DateTime.utc_now(), 1800, :second),
         "scope" => ["scope.read"]
       }}
    end

    def oauth_refresh_token(_config, _params), do: {:error, :unsupported}
  end

  setup do
    original_base_url = ZaqSystem.get_global_base_url()
    original_channels = Application.get_env(:zaq, :channels)

    on_exit(fn ->
      :ok = ZaqSystem.set_global_base_url(original_base_url)

      if is_nil(original_channels) do
        Application.delete_env(:zaq, :channels)
      else
        Application.put_env(:zaq, :channels, original_channels)
      end
    end)

    :ok
  end

  defp create_credential!(attrs \\ %{}) do
    base = %{
      name: "oauth-cred-#{Elixir.System.unique_integer([:positive])}",
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

  defp create_data_source_config!(provider) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      "name" => "oauth-config-#{Elixir.System.unique_integer([:positive])}",
      "provider" => provider,
      "kind" => "data_source",
      "enabled" => true,
      "settings" => %{}
    })
    |> Repo.insert!()
  end

  defp dispatch_finalize_callback(provider, params, mod \\ OAuth) do
    event =
      Event.new(
        %{module: mod, function: :finalize_callback, args: [provider, params]},
        :engine,
        opts: [action: :invoke]
      )

    NodeRouter.dispatch(event).response
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

  test "build_authorize_url/2 succeeds for configured oauth provider" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: TestOAuthBridge}
    })

    on_exit(fn ->
      if is_nil(original_channels) do
        Application.delete_env(:zaq, :channels)
      else
        Application.put_env(:zaq, :channels, original_channels)
      end
    end)

    credential = create_credential!()
    _config = create_data_source_config!("google_drive")

    assert {:ok, url} =
             OAuth.build_authorize_url(credential, %{
               "resource_type" => "data_source",
               "resource_id" => "42",
               "owner_type" => "org",
               "metadata" => %{"source" => "unit"}
             })

    assert url == "https://oauth.example/authorize"
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
    :ok = ZaqSystem.set_global_base_url("https://zaq.example")

    assert OAuth.redirect_uri_for("google_drive") ==
             "https://zaq.example/channels/oauth2/google_drive/redirect"
  end

  test "finalize_callback/2 attempts credential fetch and code exchange for valid state" do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "oauth-config",
        "provider" => "google_drive",
        "kind" => "data_source",
        "enabled" => true,
        "settings" => %{}
      })
      |> Repo.insert!()

    credential = create_credential!()

    state =
      OAuthState.sign(%{
        "credential_id" => credential.id,
        "provider" => "google_drive",
        "resource_type" => "data_source",
        "resource_id" => Integer.to_string(config.id),
        "owner_type" => "org",
        "owner_id" => nil,
        "metadata" => %{"source" => "test"}
      })

    assert {:error, _reason} =
             OAuth.finalize_callback("google_drive", %{"state" => state, "code" => "oauth-code"})
  end

  test "finalize_callback/2 issues grant for configured oauth provider" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: TestOAuthBridge}
    })

    on_exit(fn ->
      if is_nil(original_channels) do
        Application.delete_env(:zaq, :channels)
      else
        Application.put_env(:zaq, :channels, original_channels)
      end
    end)

    credential = create_credential!()
    _config = create_data_source_config!("google_drive")

    state =
      OAuthState.sign(%{
        "credential_id" => credential.id,
        "provider" => "google_drive",
        "resource_type" => "data_source",
        "resource_id" => "42",
        "owner_type" => "org",
        "owner_id" => nil,
        "metadata" => %{"source" => "unit"}
      })

    assert {:ok, grant} =
             OAuth.finalize_callback("google_drive", %{"state" => state, "code" => "oauth-code"})

    assert grant.provider == "google_drive"
    assert grant.auth_kind == "oauth2"
    assert grant.resource_type == "data_source"
    assert grant.resource_id == "42"
  end

  test "finalize_callback/2 persists refresh token when exchange payload uses string keys" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: StringKeyOAuthBridge}
    })

    on_exit(fn ->
      if is_nil(original_channels) do
        Application.delete_env(:zaq, :channels)
      else
        Application.put_env(:zaq, :channels, original_channels)
      end
    end)

    credential = create_credential!()
    _config = create_data_source_config!("google_drive")

    state =
      OAuthState.sign(%{
        "credential_id" => credential.id,
        "provider" => "google_drive",
        "resource_type" => "data_source",
        "resource_id" => "42",
        "owner_type" => "org",
        "owner_id" => nil,
        "metadata" => %{"source" => "unit"}
      })

    assert {:ok, grant} =
             OAuth.finalize_callback("google_drive", %{"state" => state, "code" => "oauth-code"})

    assert EncryptedString.decrypt!(grant.refresh_token) == "string-refresh-token"
  end

  test "build_authorize_url/2 maps invalid bridge response" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: InvalidOAuthBridge}
    })

    on_exit(fn ->
      if is_nil(original_channels) do
        Application.delete_env(:zaq, :channels)
      else
        Application.put_env(:zaq, :channels, original_channels)
      end
    end)

    credential = create_credential!()
    _config = create_data_source_config!("google_drive")

    assert {:error, {:invalid_oauth_response, :invalid}} =
             OAuth.build_authorize_url(credential, %{"resource_type" => "data_source"})
  end

  test "finalize_callback/2 maps invalid exchange response" do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: InvalidOAuthBridge}
    })

    on_exit(fn ->
      if is_nil(original_channels) do
        Application.delete_env(:zaq, :channels)
      else
        Application.put_env(:zaq, :channels, original_channels)
      end
    end)

    credential = create_credential!()
    _config = create_data_source_config!("google_drive")

    state =
      OAuthState.sign(%{
        "credential_id" => credential.id,
        "provider" => "google_drive",
        "resource_type" => "data_source",
        "resource_id" => "42",
        "owner_type" => "org",
        "owner_id" => nil,
        "metadata" => %{}
      })

    assert {:error, {:invalid_oauth_response, :invalid}} =
             OAuth.finalize_callback("google_drive", %{"state" => state, "code" => "oauth-code"})
  end

  describe "NodeRouter dispatch integration" do
    test "dispatches finalize_callback through :engine invoke and issues grant" do
      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: TestOAuthBridge}
      })

      on_exit(fn ->
        if is_nil(original_channels) do
          Application.delete_env(:zaq, :channels)
        else
          Application.put_env(:zaq, :channels, original_channels)
        end
      end)

      credential = create_credential!()
      _config = create_data_source_config!("google_drive")

      state =
        OAuthState.sign(%{
          "credential_id" => credential.id,
          "provider" => "google_drive",
          "resource_type" => "data_source",
          "resource_id" => "42",
          "owner_type" => "org",
          "owner_id" => nil,
          "metadata" => %{"source" => "node_router"}
        })

      assert {:ok, grant} =
               dispatch_finalize_callback("google_drive", %{
                 "state" => state,
                 "code" => "oauth-code"
               })

      assert grant.provider == "google_drive"
      assert grant.auth_kind == "oauth2"
      assert grant.resource_type == "data_source"
      assert grant.resource_id == "42"
    end

    test "dispatches finalize_callback validation errors through :engine invoke" do
      assert {:error, :invalid_callback_params} =
               dispatch_finalize_callback("google_drive", %{"state" => "x"})
    end

    test "dispatches provider mismatch through :engine invoke" do
      credential = create_credential!()

      state =
        OAuthState.sign(%{
          "credential_id" => credential.id,
          "provider" => "sharepoint"
        })

      assert {:error, :provider_mismatch} =
               dispatch_finalize_callback("google_drive", %{
                 "state" => state,
                 "code" => "oauth-code"
               })
    end
  end
end
