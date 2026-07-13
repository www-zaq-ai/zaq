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

    def oauth_authorize_url(_config, params) do
      maybe_send({:oauth_authorize_params, params})
      {:ok, "https://oauth.example/authorize"}
    end

    def oauth_exchange_code(_config, params) do
      maybe_send({:oauth_exchange_params, params})

      {:ok,
       %{
         access_token: "access-token",
         refresh_token: "refresh-token",
         expires_at: DateTime.add(DateTime.utc_now(), 1800, :second),
         scopes: ["scope.read"]
       }}
    end

    def oauth_refresh_token(_config, _params), do: {:error, :unsupported}

    defp maybe_send(message) do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
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

  defmodule GenericOAuthHTTPClient do
    def post(opts) do
      maybe_send({:generic_oauth_post_opts, opts})

      case opts[:form]["grant_type"] do
        "authorization_code" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id_token" =>
                 token(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_123"}}),
               "access_token" => "generic-access-token",
               "refresh_token" => "generic-refresh-token",
               "expires_in" => 3600,
               "scope" => "openid profile"
             }
           }}

        "refresh_token" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id_token" => token(%{"organizations" => [%{"id" => "acct_refreshed"}]}),
               "access_token" => "refreshed-generic-access-token",
               "refresh_token" => "rotated-refresh-token",
               "expires_in" => 7200,
               "scope" => "openid profile"
             }
           }}

        "urn:ietf:params:oauth:grant-type:token-exchange" ->
          raise "Codex OAuth must use the first-leg access token, not token exchange"
      end
    end

    defp token(claims) do
      [
        Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false),
        Base.url_encode64(Jason.encode!(claims), padding: false),
        "signature"
      ]
      |> Enum.join(".")
    end

    defp maybe_send(message) do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
  end

  setup do
    original_base_url = ZaqSystem.get_global_base_url()
    original_channels = Application.get_env(:zaq, :channels)
    original_http_client = Application.get_env(:zaq, :connect_oauth_http_client)

    on_exit(fn ->
      :ok = ZaqSystem.set_global_base_url(original_base_url)

      if is_nil(original_channels) do
        Application.delete_env(:zaq, :channels)
      else
        Application.put_env(:zaq, :channels, original_channels)
      end

      if is_nil(original_http_client) do
        Application.delete_env(:zaq, :connect_oauth_http_client)
      else
        Application.put_env(:zaq, :connect_oauth_http_client, original_http_client)
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

  test "build_authorize_url/2 passes Codex metadata with computed redirect uri and PKCE params" do
    :ok = ZaqSystem.set_global_base_url("https://zaq.example")

    credential =
      create_credential!(%{
        metadata: %{
          "auth_profile" => "openai_chatgpt_codex",
          "authorize_url" => "https://auth.openai.com/oauth/authorize",
          "token_url" => "https://auth.openai.com/oauth/token",
          "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
          "scope" => "openid profile email offline_access",
          "authorize_params" => %{
            "id_token_add_organizations" => "true",
            "codex_cli_simplified_flow" => "true",
            "originator" => "zaqos"
          }
        }
      })

    assert {:ok, url} =
             OAuth.build_authorize_url(credential, %{
               "resource_type" => "data_source",
               "resource_id" => "42"
             })

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert url =~ "https://auth.openai.com/oauth/authorize"
    assert query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
    assert query["redirect_uri"] == "http://localhost:1455/auth/callback"

    assert query["scope"] == "openid profile email offline_access"

    assert query["id_token_add_organizations"] == "true"
    assert query["codex_cli_simplified_flow"] == "true"
    assert query["originator"] == "zaqos"
    assert query["code_challenge_method"] == "S256"
    assert is_binary(query["code_challenge"])
    refute String.contains?(url, "code_verifier")
  end

  test "generic metadata OAuth flow exchanges code and creates ai provider credential grant" do
    Process.register(self(), GenericOAuthHTTPClient)
    Application.put_env(:zaq, :connect_oauth_http_client, GenericOAuthHTTPClient)
    :ok = ZaqSystem.set_global_base_url("https://zaq.example")

    credential =
      create_credential!(%{
        provider: "openai",
        metadata: %{
          "auth_profile" => "openai_chatgpt_codex",
          "authorize_url" => "https://auth.openai.com/oauth/authorize",
          "token_url" => "https://auth.openai.com/oauth/token",
          "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
          "scope" => "openid profile email offline_access",
          "authorize_params" => %{"originator" => "zaqos"}
        }
      })

    assert {:ok, url} =
             OAuth.build_authorize_url(credential, %{
               "resource_type" => "ai_provider_credential",
               "resource_id" => "123",
               "owner_type" => "org",
               "metadata" => %{"source" => "test"}
             })

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "auth.openai.com"
    assert query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
    assert query["redirect_uri"] == "http://localhost:1455/auth/callback"
    assert query["originator"] == "zaqos"
    assert query["code_challenge_method"] == "S256"

    assert {:ok, grant} =
             OAuth.finalize_callback("openai", %{
               "state" => query["state"],
               "code" => "oauth-code"
             })

    assert grant.provider == "openai"
    assert grant.resource_type == "ai_provider_credential"
    assert grant.resource_id == "123"
    assert EncryptedString.decrypt!(grant.access_token) == "generic-access-token"
    assert grant.metadata["source"] == "test"
    assert grant.metadata["chatgpt_account_id"] == "acct_123"

    assert_receive {:generic_oauth_post_opts, code_exchange_opts}
    assert code_exchange_opts[:url] == "https://auth.openai.com/oauth/token"
    assert code_exchange_opts[:form]["redirect_uri"] == "http://localhost:1455/auth/callback"
    assert is_binary(code_exchange_opts[:form]["code_verifier"])

    refute_receive {:generic_oauth_post_opts, _token_exchange_opts}

    Process.unregister(GenericOAuthHTTPClient)
  end

  test "refresh_grant uses generic metadata refresh for Codex OAuth" do
    Process.register(self(), GenericOAuthHTTPClient)
    Application.put_env(:zaq, :connect_oauth_http_client, GenericOAuthHTTPClient)

    credential =
      create_credential!(%{
        provider: "openai",
        metadata: %{
          "auth_profile" => "openai_chatgpt_codex",
          "token_url" => "https://auth.openai.com/oauth/token",
          "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann",
          "scope" => "openid profile email offline_access"
        }
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "ai_provider_credential",
        resource_id: "123",
        owner_type: "org",
        metadata: %{"source" => "existing"},
        access_token: "old-oauth-access-token",
        refresh_token: "old-refresh-token",
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        scopes: ["openid", "profile"]
      })

    assert {:ok, refreshed_grant} = Connect.refresh_grant(grant)

    assert EncryptedString.decrypt!(refreshed_grant.access_token) ==
             "refreshed-generic-access-token"

    assert EncryptedString.decrypt!(refreshed_grant.refresh_token) == "rotated-refresh-token"
    assert refreshed_grant.metadata["source"] == "existing"
    assert refreshed_grant.metadata["chatgpt_account_id"] == "acct_refreshed"

    assert_receive {:generic_oauth_post_opts, refresh_opts}
    assert refresh_opts[:url] == "https://auth.openai.com/oauth/token"
    assert refresh_opts[:form]["grant_type"] == "refresh_token"
    assert refresh_opts[:form]["refresh_token"] == "old-refresh-token"

    refute_receive {:generic_oauth_post_opts, _token_exchange_opts}

    Process.unregister(GenericOAuthHTTPClient)
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

    assert OAuth.redirect_uri_for("openai") ==
             "https://zaq.example/channels/oauth2/openai/redirect"
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
