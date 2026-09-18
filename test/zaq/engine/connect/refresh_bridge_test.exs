defmodule Zaq.Engine.Connect.RefreshBridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.Person
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.DataSourceBridge
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Grant
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

    b = credential("B", "B-secret", ["broad"])

    channel_config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: Ecto.UUID.generate(),
        provider: "google_drive",
        kind: "data_source",
        enabled: true,
        settings: %{"connect" => %{"credential_id" => to_string(b.id)}}
      })
      |> Repo.insert!()

    %{channel_config: channel_config}
  end

  for owner <- [:org, :person] do
    test "canonical #{owner} refresh never borrows channel B secret when A explicitly has none" do
      a = credential("A", nil, [])
      grant = canonical_grant(a, unquote(owner))
      # Only provider HTTP is controlled; all Connect/router/bridge boundaries are real.
      Req.Test.stub(ConnectOAuthAttemptHTTP, fn conn ->
        send(self(), :unexpected_provider_request)
        Req.Test.json(conn, %{"access_token" => "borrowed-token"})
      end)

      assert {:error, :refresh_failed} = Connect.refresh_grant(grant, @opts)
      refute_received :unexpected_provider_request
      assert Repo.get!(Grant, grant.id).access_token == "old-A"
    end
  end

  for scopes <- [[], ["read"]] do
    test "canonical refresh with #{inspect(scopes)} scopes needs no redirect and uses only A material" do
      a = credential("A", "A-secret", unquote(scopes))
      grant = canonical_grant(a, :org)

      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        form = URI.decode_query(body)
        assert form["client_id"] == "A-client"
        assert form["client_secret"] == "A-secret"
        assert form["refresh_token"] == "A-refresh"
        assert form["grant_type"] == "refresh_token"
        assert (form["scope"] || "") == Enum.join(unquote(scopes), " ")
        refute Map.has_key?(form, "redirect_uri")
        Req.Test.json(conn, %{"access_token" => "new-A", "expires_in" => 3600})
      end)

      assert {:ok, updated} = Connect.refresh_grant(grant, @opts)
      assert updated.access_token == "new-A"
      assert updated.scopes == unquote(scopes)
      assert updated.refresh_token == "A-refresh"
    end
  end

  test "explicit refresh rejects missing client identity rather than selecting channel B" do
    for client_id <- [nil, ""] do
      assert {:error, :explicit_oauth_transport_required} =
               DataSourceBridge.oauth_refresh_token(
                 "google_drive",
                 %{"client_id" => client_id, "refresh_token" => "A-refresh"},
                 oauth_credentials: :explicit
               )
    end
  end

  for owner <- ["org", "user"] do
    test "legacy #{owner} refresh retains channel credential fallback", %{channel_config: config} do
      a = credential("A", nil, [])

      assert {:ok, grant} =
               Connect.issue_grant(%{
                 credential_id: a.id,
                 provider: a.provider,
                 auth_kind: "oauth2",
                 resource_type: "data_source",
                 resource_id: to_string(config.id),
                 owner_type: unquote(owner),
                 access_token: "old-A",
                 refresh_token: "A-refresh"
               })

      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        form = URI.decode_query(body)
        assert form["client_id"] == "A-client"
        assert form["client_secret"] == "B-secret"
        assert form["refresh_token"] == "A-refresh"
        Req.Test.json(conn, %{"access_token" => "legacy-token"})
      end)

      assert {:ok, %{access_token: "legacy-token"}} = Connect.refresh_grant(grant, @opts)
    end
  end

  defp credential(name, secret, scopes) do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "#{name}-#{Ecto.UUID.generate()}",
        provider: "google_drive",
        auth_kind: "oauth2",
        secret_binding: :grant,
        personal_credential_policy: :required,
        client_id: "#{name}-client",
        client_secret: secret,
        scopes: scopes
      })

    credential
  end

  defp canonical_grant(credential, owner) do
    owner =
      if owner == :person do
        person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Refresh owner"}))
        {:person, person.id}
      else
        :org
      end

    {:ok, dto} =
      Connect.replace_credential_grant(credential, owner, %{
        access_token: "old-A",
        refresh_token: "A-refresh"
      })

    Repo.get!(Grant, dto.grant_id)
  end
end
