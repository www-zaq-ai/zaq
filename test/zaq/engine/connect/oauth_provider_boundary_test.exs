defmodule Zaq.Engine.Connect.OAuthProviderBoundaryTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.Person
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.{DataSourceBridge, JidoConnectBridge}
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, OAuth, OAuthAttempts, PersonCredentials}
  alias Zaq.TestSupport.{ConnectOAuthAttemptConfig, ConnectOAuthAttemptHTTP}

  @opts [config: ConnectOAuthAttemptConfig]
  setup {Req.Test, :verify_on_exit!}

  setup do
    Code.ensure_loaded!(ConnectOAuthAttemptConfig)
    previous_req = Application.get_env(:jido_connect_google, :google_oauth_req_options)
    previous_secret = System.get_env("GOOGLE_CLIENT_SECRET")
    System.put_env("GOOGLE_CLIENT_SECRET", "AMBIENT_SECRET_SENTINEL")

    Application.put_env(:jido_connect_google, :google_oauth_req_options,
      plug: {Req.Test, ConnectOAuthAttemptHTTP}
    )

    on_exit(fn ->
      if previous_req,
        do: Application.put_env(:jido_connect_google, :google_oauth_req_options, previous_req),
        else: Application.delete_env(:jido_connect_google, :google_oauth_req_options)

      if previous_secret,
        do: System.put_env("GOOGLE_CLIENT_SECRET", previous_secret),
        else: System.delete_env("GOOGLE_CLIENT_SECRET")
    end)

    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Provider boundary"}))

    {:ok, b} =
      Connect.create_credential(%{
        name: Ecto.UUID.generate(),
        provider: "google_drive",
        auth_kind: "oauth2",
        client_id: "B-client",
        client_secret: "CHANNEL_SECRET_SENTINEL",
        scopes: ["broad"]
      })

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: Ecto.UUID.generate(),
      provider: "google_drive",
      kind: "data_source",
      enabled: true,
      settings: %{"connect" => %{"credential_id" => to_string(b.id)}}
    })
    |> Repo.insert!()

    %{person: person}
  end

  test "trusted Person fallback exchange submits the exact S256 verifier and only bound secrets",
       %{person: person} do
    credential = credential("A-secret")
    query = start(person, credential)
    parent = self()

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:provider_form, URI.decode_query(body), conn.host})

      Req.Test.json(conn, %{
        "access_token" => "bound-access",
        "refresh_token" => "bound-refresh",
        "expires_in" => 3600
      })
    end)

    assert {:ok, %{status: "active"}} = finish(query)
    assert_received {:provider_form, form, "oauth2.googleapis.com"}
    assert is_binary(form["code_verifier"])

    assert Base.url_encode64(:crypto.hash(:sha256, form["code_verifier"]), padding: false) ==
             query["code_challenge"]

    assert query["code_challenge_method"] == "S256"
    assert form["client_id"] == "A-client"
    assert form["client_secret"] == "A-secret"
    assert form["redirect_uri"] == query["redirect_uri"]
    refute inspect(form) =~ "AMBIENT_SECRET"
    refute inspect(form) =~ "CHANNEL_SECRET"

    assert Repo.get_by!(Grant, credential_id: credential.id, owner_type: "person").access_token ==
             "bound-access"
  end

  test "catalog fallback code exchange cannot borrow a nonempty ambient secret", %{person: person} do
    credential = credential(nil)
    query = start(person, credential)
    parent = self()

    Req.Test.stub(ConnectOAuthAttemptHTTP, fn conn ->
      send(parent, :unbound_request)

      Req.Test.json(conn, %{
        "access_token" => "borrowed-access",
        "refresh_token" => "refresh",
        "expires_in" => 3600
      })
    end)

    assert {:error, :oauth_failed} = finish(query)
    refute_received :unbound_request
    refute Repo.get_by(Grant, credential_id: credential.id)
  end

  test "configured generic public client omits ambient secret and retains PKCE", %{person: person} do
    credential = credential(nil, %{"token_url" => "https://provider.example/token"})
    query = start(person, credential)
    parent = self()

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:public_form, URI.decode_query(body)})

      Req.Test.json(conn, %{
        "access_token" => "public-access",
        "refresh_token" => "public-refresh",
        "expires_in" => 3600
      })
    end)

    assert {:ok, %{status: "active"}} = finish(query)
    assert_received {:public_form, form}
    refute Map.has_key?(form, "client_secret")

    assert Base.url_encode64(:crypto.hash(:sha256, form["code_verifier"]), padding: false) ==
             query["code_challenge"]

    grant = Repo.get_by!(Grant, credential_id: credential.id, owner_type: "person")

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:public_refresh_form, URI.decode_query(body)})
      Req.Test.json(conn, %{"access_token" => "public-refreshed", "expires_in" => 3600})
    end)

    assert {:ok, %{access_token: "public-refreshed"}} = Connect.refresh_grant(grant, @opts)
    assert_received {:public_refresh_form, refresh_form}
    refute Map.has_key?(refresh_form, "client_secret")
    assert refresh_form["refresh_token"] == "public-refresh"
  end

  test "explicit token operations cannot reach unsafe dependency helpers directly" do
    params = %{
      "client_id" => "A-client",
      "client_secret" => "A-secret",
      "code" => "code",
      "redirect_uri" => "https://zaq.example/callback",
      "code_verifier" => "verifier",
      "refresh_token" => "refresh"
    }

    assert {:error, :explicit_oauth_transport_required} =
             DataSourceBridge.oauth_exchange_code("google_drive", params,
               oauth_credentials: :explicit
             )

    assert {:error, :explicit_oauth_transport_required} =
             DataSourceBridge.oauth_refresh_token("google_drive", params,
               oauth_credentials: :explicit
             )

    assert {:error, :unsupported} =
             JidoConnectBridge.oauth_token_endpoint(%{provider: "no-such-provider"})
  end

  test "legacy exchange and refresh retain the dependency's ambient secret fallback" do
    b = Repo.get_by!(Credential, client_id: "B-client")
    assert {:ok, _} = Connect.update_credential(b, %{client_secret: nil})
    parent = self()

    Req.Test.expect(ConnectOAuthAttemptHTTP, 2, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:legacy_form, URI.decode_query(body)})
      Req.Test.json(conn, %{"access_token" => "legacy-access", "expires_in" => 3600})
    end)

    assert {:ok, _} =
             DataSourceBridge.oauth_exchange_code("google_drive", %{"code" => "legacy-code"})

    assert_received {:legacy_form, exchange}
    assert exchange["grant_type"] == "authorization_code"
    assert exchange["client_id"] == "B-client"
    assert exchange["client_secret"] == "AMBIENT_SECRET_SENTINEL"

    assert {:ok, _} =
             DataSourceBridge.oauth_refresh_token("google_drive", %{
               "refresh_token" => "legacy-refresh"
             })

    assert_received {:legacy_form, refresh}
    assert refresh["grant_type"] == "refresh_token"
    assert refresh["client_id"] == "B-client"
    assert refresh["client_secret"] == "AMBIENT_SECRET_SENTINEL"
  end

  test "unavailable catalog endpoint fails closed without invoking provider token helpers" do
    credential = %{credential("A-secret") | provider: "no-such-provider"}

    assert {:error, :unsupported_oauth_endpoint} =
             OAuth.exchange_attempt(
               credential,
               "code",
               %{redirect_uri: "https://zaq.example/callback", pkce_verifier: "verifier"},
               @opts
             )
  end

  defp credential(secret, metadata \\ %{}) do
    {:ok, credential} =
      Connect.create_credential(%{
        name: Ecto.UUID.generate(),
        provider: "google_drive",
        auth_kind: "oauth2",
        secret_binding: :grant,
        personal_credential_policy: :required,
        client_id: "A-client",
        client_secret: secret,
        scopes: [],
        metadata: metadata
      })

    credential
  end

  defp start(person, credential) do
    assert {:ok, %{authorize_url: url}} =
             PersonCredentials.start_oauth(person, credential.id, @opts)

    URI.decode_query(URI.parse(url).query)
  end

  defp finish(query),
    do:
      OAuthAttempts.finalize_callback(
        "google_drive",
        %{"state" => query["state"], "code" => "bound-code"},
        @opts
      )
end
