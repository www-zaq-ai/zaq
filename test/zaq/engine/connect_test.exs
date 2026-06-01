defmodule Zaq.Engine.ConnectTest do
  use Zaq.DataCase, async: true

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Engine.Connect.GrantRefreshWorker
  alias Zaq.Repo
  alias Zaq.Types.EncryptedString

  defmodule StubOAuthInvalidResponse do
    def oauth_refresh_token(_config, _params), do: :unexpected
  end

  defmodule StubOAuthNoScopes do
    def oauth_refresh_token(_config, _params) do
      {:ok,
       %{
         access_token: "new-access",
         refresh_token: "new-refresh",
         expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
         scopes: nil
       }}
    end
  end

  defmodule StubOAuthMissingRefreshToken do
    def oauth_refresh_token(_config, _params) do
      {:ok,
       %{
         access_token: "new-access",
         refresh_token: nil,
         expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
         scopes: ["scope.from.refresh"]
       }}
    end
  end

  setup do
    {:ok,
     oauth_attrs: %{
       name: "OAuth2 Config",
       provider: "google_drive",
       auth_kind: "oauth2",
       request_format: "bearer",
       user_level: false,
       metadata: %{"authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth"},
       client_id: "client-id",
       client_secret: "secret"
     }}
  end

  defp create_oauth_credential(_context) do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "OAuth2 Config",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{"authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth"},
        client_id: "client-id",
        client_secret: "secret"
      })

    %{credential: credential}
  end

  defp issue_oauth_grant(credential, overrides \\ []) do
    base = %{
      credential_id: credential.id,
      resource_type: "data_source",
      resource_id: "99",
      owner_type: "org",
      metadata: %{},
      access_token: "tok",
      refresh_token: "ref"
    }

    {:ok, grant} = Connect.issue_grant(Map.merge(base, Map.new(overrides)))
    grant
  end

  describe "credentials" do
    test "creates provider-scoped oauth2 credential" do
      attrs = %{
        name: "Google Drive Org OAuth",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{"authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth"},
        client_id: "client-id",
        client_secret: "super-secret",
        scopes: ["drive.readonly"]
      }

      assert {:ok, %Credential{} = credential} = Connect.create_credential(attrs)
      credential = Repo.get!(Credential, credential.id)

      assert credential.provider == "google_drive"
      assert credential.client_secret == "super-secret"
      refute Map.has_key?(credential, :owner_type)
      refute Map.has_key?(credential, :resource_type)
    end

    test "preserves existing api_key when blank update is sent" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Sharepoint API key",
          provider: "sharepoint",
          auth_kind: "api_key",
          request_format: "raw",
          user_level: false,
          metadata: %{},
          api_key: "abc"
        })

      assert {:ok, updated} = Connect.update_credential(credential, %{"api_key" => ""})
      updated = Repo.get!(Credential, updated.id)
      assert updated.api_key == "abc"
    end

    test "fetch_credential/1 returns not_found for nil and get_credential!/1 + delete_credential/1 work" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "To delete",
          provider: "google_drive",
          auth_kind: "api_key",
          request_format: "raw",
          user_level: false,
          metadata: %{},
          api_key: "abc"
        })

      assert {:error, :not_found} = Connect.fetch_credential(nil)
      assert %Credential{id: id} = Connect.get_credential!(credential.id)
      assert id == credential.id
      assert {:ok, _deleted} = Connect.delete_credential(credential)
      assert_raise Ecto.NoResultsError, fn -> Connect.get_credential!(credential.id) end
    end

    test "update_credential accepts already encrypted values" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Broken key",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "secret"
        })

      {:ok, encrypted} = EncryptedString.encrypt("new-secret")
      assert {:ok, updated} = Connect.update_credential(credential, %{client_secret: encrypted})
      assert updated.client_secret == encrypted
    end

    test "list_credentials/0 returns all credentials ordered by name" do
      {:ok, _a} =
        Connect.create_credential(%{
          name: "Zed",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "c1",
          client_secret: "s1"
        })

      {:ok, _b} =
        Connect.create_credential(%{
          name: "Alpha",
          provider: "sharepoint",
          auth_kind: "api_key",
          request_format: "raw",
          user_level: false,
          metadata: %{},
          api_key: "k2"
        })

      result = Connect.list_credentials()
      names = Enum.map(result, & &1.name)
      assert names == ["Alpha", "Zed"]
    end

    test "fetch_credential/1 returns not_found for non-existent id" do
      assert {:error, :not_found} = Connect.fetch_credential(-1)
    end

    test "change_credential/2 returns a changeset" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "To change",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "s"
        })

      changeset = Connect.change_credential(credential, %{name: "Changed"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :name) == "Changed"
    end

    test "update_credential drops blank atom-keyed secret attrs" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Drop blank",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "s"
        })

      assert {:ok, updated} = Connect.update_credential(credential, %{client_secret: ""})
      updated = Repo.get!(Credential, updated.id)
      assert updated.client_secret == "s"
    end
  end

  describe "grants" do
    setup [:create_oauth_credential]

    test "issues api_key grant and copies token from credential when missing in attrs" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Drive API key",
          provider: "google_drive",
          auth_kind: "api_key",
          request_format: "raw",
          user_level: false,
          metadata: %{},
          api_key: "shared-token"
        })

      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: "42",
                 owner_type: "org",
                 owner_id: nil,
                 metadata: %{"note" => "bo-grant"}
               })

      grant = Repo.get!(Grant, grant.id)

      assert grant.api_key == "shared-token"
      assert grant.provider == "google_drive"
      assert grant.auth_kind == "api_key"
    end

    test "issues jwt_bearer grant and copies scopes from credential when missing" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Drive JWT",
          provider: "google_drive",
          auth_kind: "jwt_bearer",
          request_format: "bearer",
          user_level: false,
          metadata: %{"auth_profile_id" => "service_account"},
          issuer: "svc@example.iam.gserviceaccount.com",
          private_key: "private-key",
          key_id: "kid-1",
          scopes: [
            "https://www.googleapis.com/auth/drive.readonly",
            "https://www.googleapis.com/auth/drive.metadata.readonly"
          ]
        })

      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: "42",
                 owner_type: "org",
                 owner_id: nil,
                 metadata: %{"auth_profile_id" => "service_account"}
               })

      grant = Repo.get!(Grant, grant.id)

      assert grant.auth_kind == "jwt_bearer"
      assert grant.scopes == credential.scopes
    end

    test "issues jwt_bearer grant and falls back to credential scopes when attrs scopes are empty" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Drive JWT Empty Scopes",
          provider: "google_drive",
          auth_kind: "jwt_bearer",
          request_format: "bearer",
          user_level: false,
          metadata: %{"auth_profile_id" => "service_account"},
          issuer: "svc@example.iam.gserviceaccount.com",
          private_key: "private-key",
          key_id: "kid-3",
          scopes: [
            "https://www.googleapis.com/auth/drive.readonly",
            "https://www.googleapis.com/auth/drive.metadata.readonly"
          ]
        })

      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: "43",
                 owner_type: "org",
                 owner_id: nil,
                 metadata: %{"auth_profile_id" => "service_account"},
                 scopes: []
               })

      grant = Repo.get!(Grant, grant.id)
      assert grant.scopes == credential.scopes
    end

    test "update_grant_token_cache for jwt_bearer does not overwrite scopes" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Drive JWT Update",
          provider: "google_drive",
          auth_kind: "jwt_bearer",
          request_format: "bearer",
          user_level: false,
          metadata: %{"auth_profile_id" => "service_account"},
          issuer: "svc@example.iam.gserviceaccount.com",
          private_key: "private-key",
          key_id: "kid-2",
          scopes: [
            "https://www.googleapis.com/auth/drive.readonly",
            "https://www.googleapis.com/auth/drive.metadata.readonly"
          ]
        })

      {:ok, grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "42",
          owner_type: "org",
          owner_id: nil,
          metadata: %{"auth_profile_id" => "service_account"},
          scopes: credential.scopes
        })

      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, updated} =
               Connect.update_grant_token_cache(grant, %{
                 access_token: "jwt-access-token",
                 expires_at: expires_at,
                 scopes: []
               })

      assert updated.access_token == "jwt-access-token"
      assert DateTime.to_unix(updated.expires_at) == DateTime.to_unix(expires_at)
      assert updated.scopes == credential.scopes
    end

    test "resolves latest active grant for owner and resource context", %{credential: credential} do
      assert {:ok, _grant1} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: "12",
                 owner_type: "user",
                 owner_id: 100,
                 metadata: %{},
                 access_token: "a",
                 refresh_token: "r"
               })

      assert {:ok, grant2} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: "12",
                 owner_type: "user",
                 owner_id: 100,
                 metadata: %{},
                 access_token: "b",
                 refresh_token: "r2"
               })

      selected =
        Connect.get_active_grant(%{
          provider: "google_drive",
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "user",
          owner_id: 100
        })

      assert selected.id == grant2.id
    end

    test "get_active_grant respects integer credential_id filters", %{credential: credential_a} do
      {:ok, credential_b} =
        Connect.create_credential(%{
          name: "OAuth2 Config B",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{"authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth"},
          client_id: "client-id-b",
          client_secret: "secret-b"
        })

      {:ok, grant_a} =
        Connect.issue_grant(%{
          credential_id: credential_a.id,
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "user",
          owner_id: 100,
          metadata: %{},
          access_token: "a",
          refresh_token: "r"
        })

      {:ok, grant_b} =
        Connect.issue_grant(%{
          credential_id: credential_b.id,
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "user",
          owner_id: 100,
          metadata: %{},
          access_token: "b",
          refresh_token: "r2"
        })

      selected =
        Connect.get_active_grant(%{
          provider: "google_drive",
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "user",
          owner_id: 100,
          credential_id: credential_a.id
        })

      assert selected.id == grant_a.id
      assert selected.credential_id == credential_a.id
      refute selected.id == grant_b.id
    end

    test "get_active_grant ignores invalid binary credential_id values", %{
      credential: credential_a
    } do
      {:ok, credential_b} =
        Connect.create_credential(%{
          name: "OAuth2 Config B",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{"authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth"},
          client_id: "client-id-b",
          client_secret: "secret-b"
        })

      {:ok, _grant_a} =
        Connect.issue_grant(%{
          credential_id: credential_a.id,
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "user",
          owner_id: 100,
          metadata: %{},
          access_token: "a",
          refresh_token: "r"
        })

      {:ok, grant_b} =
        Connect.issue_grant(%{
          credential_id: credential_b.id,
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "user",
          owner_id: 100,
          metadata: %{},
          access_token: "b",
          refresh_token: "r2"
        })

      selected =
        Connect.get_active_grant(%{
          provider: "google_drive",
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "user",
          owner_id: 100,
          credential_id: "abc"
        })

      assert selected.id == grant_b.id
      assert selected.credential_id == credential_b.id
    end

    test "get_active_grant ignores non-binary credential_id values", %{credential: credential_a} do
      {:ok, credential_b} =
        Connect.create_credential(%{
          name: "OAuth2 Config B",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{"authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth"},
          client_id: "client-id-b",
          client_secret: "secret-b"
        })

      {:ok, _grant_a} =
        Connect.issue_grant(%{
          credential_id: credential_a.id,
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "user",
          owner_id: 100,
          metadata: %{},
          access_token: "a",
          refresh_token: "r"
        })

      {:ok, grant_b} =
        Connect.issue_grant(%{
          credential_id: credential_b.id,
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "user",
          owner_id: 100,
          metadata: %{},
          access_token: "b",
          refresh_token: "r2"
        })

      selected =
        Connect.get_active_grant(%{
          provider: "google_drive",
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "user",
          owner_id: 100,
          credential_id: %{bad: "shape"}
        })

      assert selected.id == grant_b.id
      assert selected.credential_id == credential_b.id
    end

    test "issue_grant rejects provider mismatch for data source resource", %{
      credential: credential
    } do
      {:ok, cfg} =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Sharepoint DS",
          provider: "sharepoint",
          kind: "data_source",
          enabled: true,
          settings: %{}
        })
        |> Repo.insert()

      assert {:error, :provider_mismatch} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: cfg.id,
                 owner_type: "org",
                 metadata: %{},
                 access_token: "a",
                 refresh_token: "r"
               })
    end

    test "revoke_grant sets grant status to revoked", %{credential: credential} do
      grant = issue_oauth_grant(credential)

      assert {:ok, revoked} = Connect.revoke_grant(grant)
      assert revoked.status == "revoked"
    end

    test "delete_grant removes grant from database", %{credential: credential} do
      grant = issue_oauth_grant(credential)

      assert {:ok, %Grant{}} = Connect.delete_grant(grant)
      assert Repo.get(Grant, grant.id) == nil
    end

    test "list_grants/0 returns all grants ordered by inserted_at desc", %{credential: credential} do
      g1 = issue_oauth_grant(credential, resource_id: "10")
      g2 = issue_oauth_grant(credential, resource_id: "11")

      result = Connect.list_grants()
      ids = Enum.map(result, & &1.id)
      assert length(ids) >= 2
      assert g1.id in ids
      assert g2.id in ids
    end

    test "list_grants/1 filters by multiple fields", %{credential: credential} do
      g1 = issue_oauth_grant(credential, resource_id: "51", owner_type: "org", owner_id: 10)
      g2 = issue_oauth_grant(credential, resource_id: "52", owner_type: "user", owner_id: 20)

      assert [g1.id] == Enum.map(Connect.list_grants(resource_id: "51"), & &1.id)
      assert [g2.id] == Enum.map(Connect.list_grants(owner_type: "user"), & &1.id)
      assert [g2.id] == Enum.map(Connect.list_grants(owner_id: 20), & &1.id)

      assert Connect.list_grants(credential_id: credential.id)
             |> Enum.map(& &1.id)
             |> MapSet.new() ==
               MapSet.new([g1.id, g2.id])

      assert [] == Connect.list_grants(status: "expired")

      {:ok, revoked} = Connect.revoke_grant(g1)
      assert [revoked.id] == Enum.map(Connect.list_grants(status: "revoked"), & &1.id)
    end

    test "get_active_grant with owner_id: nil returns org-level grant", %{credential: credential} do
      grant = issue_oauth_grant(credential, owner_type: "org", owner_id: nil)

      selected =
        Connect.get_active_grant(%{
          provider: "google_drive",
          resource_type: "data_source",
          resource_id: "99",
          owner_type: "org",
          owner_id: nil
        })

      assert selected.id == grant.id
    end

    test "get_active_grant defaults owner_type to org when not provided", %{
      credential: credential
    } do
      grant = issue_oauth_grant(credential, owner_type: "org", owner_id: nil)

      selected =
        Connect.get_active_grant(%{
          provider: "google_drive",
          resource_type: "data_source",
          resource_id: "99"
        })

      assert selected.id == grant.id
    end

    test "get_active_grant excludes expired grants", %{credential: credential} do
      {:ok, expired} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "61",
          owner_type: "org",
          metadata: %{},
          access_token: "a",
          refresh_token: "r",
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      assert Repo.get(Grant, expired.id) != nil

      selected =
        Connect.get_active_grant(%{
          provider: "google_drive",
          resource_type: "data_source",
          resource_id: "61",
          owner_type: "org"
        })

      assert selected == nil
    end

    test "issue_grant accepts non-data_source resource type (mcp)" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "MCP Config",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "s"
        })

      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "mcp",
                 resource_id: "mcp-srv",
                 owner_type: "org",
                 metadata: %{},
                 access_token: "tok"
               })

      assert grant.resource_type == "mcp"
    end

    test "issue_grant uses credential's auth_kind as fallback when not provided in attrs" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Auto auth_kind",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "s"
        })

      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "mcp",
                 resource_id: "auto-auth",
                 owner_type: "org",
                 metadata: %{},
                 access_token: "tok"
               })

      assert grant.auth_kind == "oauth2"
    end

    test "issue_grant normalizes integer resource_id to string", %{credential: credential} do
      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "mcp",
                 resource_id: 9876,
                 owner_type: "org",
                 metadata: %{},
                 access_token: "tok"
               })

      assert grant.resource_id == "9876"
    end

    test "expiring_oauth_grants returns grants expiring within window", %{credential: credential} do
      {:ok, grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "71",
          owner_type: "org",
          metadata: %{},
          access_token: "a",
          refresh_token: "r",
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        })

      result = Connect.expiring_oauth_grants()
      ids = Enum.map(result, & &1.id)
      assert grant.id in ids
    end

    test "expiring_oauth_grants excludes grants without refresh_token", %{credential: credential} do
      {:ok, no_refresh} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "72",
          owner_type: "org",
          metadata: %{},
          access_token: "a",
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        })

      result = Connect.expiring_oauth_grants()
      ids = Enum.map(result, & &1.id)
      refute no_refresh.id in ids
    end

    test "expiring_oauth_grants excludes grants outside the window", %{credential: credential} do
      {:ok, far_future} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "73",
          owner_type: "org",
          metadata: %{},
          access_token: "a",
          refresh_token: "r",
          expires_at: DateTime.add(DateTime.utc_now(), 3600 * 24, :second)
        })

      result = Connect.expiring_oauth_grants(DateTime.utc_now(), 600)
      ids = Enum.map(result, & &1.id)
      refute far_future.id in ids
    end

    test "issue_grant with data_source matching ChannelConfig provider succeeds" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Matching DS",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "s"
        })

      {:ok, cfg} =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Google Drive DS",
          provider: "google_drive",
          kind: "data_source",
          enabled: true,
          settings: %{}
        })
        |> Repo.insert()

      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: cfg.id,
                 owner_type: "org",
                 metadata: %{},
                 access_token: "a",
                 refresh_token: "r"
               })

      assert grant.resource_id == to_string(cfg.id)
    end

    test "issue_grant with api_key credential and non-nil api_key in attrs preserves the provided key" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Key copy test",
          provider: "google_drive",
          auth_kind: "api_key",
          request_format: "raw",
          user_level: false,
          metadata: %{},
          api_key: "fallback-key"
        })

      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "mcp",
                 resource_id: "custom-key",
                 owner_type: "org",
                 metadata: %{},
                 api_key: "explicit-key"
               })

      grant = Repo.get!(Grant, grant.id)
      assert grant.api_key == "explicit-key"
    end

    test "next_refresh_jobs_for_grants with scheduled job returns non-nil scheduled time", %{
      credential: credential
    } do
      grant = issue_oauth_grant(credential)

      {:ok, _job} =
        Repo.insert(%Oban.Job{
          queue: "default",
          worker: to_string(GrantRefreshWorker),
          args: %{"grant_id" => grant.id},
          state: "scheduled",
          scheduled_at: DateTime.add(DateTime.utc_now(), 60, :second)
        })

      schedule = Connect.next_refresh_jobs_for_grants([grant])
      assert not is_nil(schedule[grant.id])
    end

    test "next_refresh_jobs_for_grants returns empty map for empty list" do
      assert Connect.next_refresh_jobs_for_grants([]) == %{}
    end

    test "schedule_refresh enqueues oban job", %{credential: credential} do
      grant = issue_oauth_grant(credential)

      assert {:ok, job} = Connect.schedule_refresh(grant)
      assert job.worker == "Zaq.Engine.Connect.GrantRefreshWorker"
    end

    test "refresh_grant returns error when dispatch fails (no bridge configured)", %{
      credential: credential
    } do
      grant = issue_oauth_grant(credential)

      assert {:error, {:channel_not_configured, "google_drive"}} = Connect.refresh_grant(grant)
    end

    test "next_refresh_jobs_for_grants returns empty map when all grant ids are nil" do
      grants = [%{id: nil}, %{id: nil}]
      assert Connect.next_refresh_jobs_for_grants(grants) == %{}
    end

    test "issue_grant with data_source resource_type and non-existent ChannelConfig returns ok",
         %{
           credential: credential
         } do
      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: 999_999,
                 owner_type: "org",
                 metadata: %{},
                 access_token: "tok",
                 refresh_token: "ref"
               })

      assert grant.resource_id == "999999"
    end
  end

  describe "refresh_grant" do
    test "returns not_found when credential does not exist" do
      grant = %Zaq.Engine.Connect.Grant{
        id: 0,
        credential_id: -1,
        provider: "google_drive",
        auth_kind: "oauth2",
        resource_type: "data_source",
        resource_id: "x",
        owner_type: "org",
        request_format: "bearer",
        status: "active",
        metadata: %{},
        access_token: "tok",
        refresh_token: "ref"
      }

      assert Connect.refresh_grant(grant) == {:error, :not_found}
    end

    test "returns invalid_refresh_response when bridge returns unsupported payload" do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "cfg-refresh-invalid-#{System.unique_integer([:positive])}",
        provider: "google_drive",
        kind: "data_source",
        enabled: true,
        settings: %{}
      })
      |> Repo.insert!()

      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: StubOAuthInvalidResponse}
      })

      on_exit(fn ->
        if original_channels do
          Application.put_env(:zaq, :channels, original_channels)
        else
          Application.delete_env(:zaq, :channels)
        end
      end)

      {:ok, credential} =
        Connect.create_credential(%{
          name: "Invalid refresh payload credential",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "secret",
          scopes: ["scope.a"]
        })

      {:ok, grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "mcp",
          resource_id: "invalid-response",
          owner_type: "org",
          metadata: %{},
          access_token: "old-access",
          refresh_token: "old-refresh",
          scopes: ["scope.old"]
        })

      assert {:error, {:invalid_refresh_response, :unexpected}} = Connect.refresh_grant(grant)
    end

    test "refresh_grant falls back to existing scopes when payload omits scopes" do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "cfg-refresh-fallback-#{System.unique_integer([:positive])}",
        provider: "google_drive",
        kind: "data_source",
        enabled: true,
        settings: %{}
      })
      |> Repo.insert!()

      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: StubOAuthNoScopes}
      })

      on_exit(fn ->
        if original_channels do
          Application.put_env(:zaq, :channels, original_channels)
        else
          Application.delete_env(:zaq, :channels)
        end
      end)

      {:ok, credential} =
        Connect.create_credential(%{
          name: "Fallback refresh payload credential",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "secret",
          scopes: ["scope.from.credential"]
        })

      {:ok, grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "mcp",
          resource_id: "fallback-response",
          owner_type: "org",
          metadata: %{},
          access_token: "old-access",
          refresh_token: "old-refresh",
          scopes: ["scope.from.grant"]
        })

      assert {:ok, refreshed} = Connect.refresh_grant(grant)
      assert refreshed.access_token != "old-access"
      assert refreshed.refresh_token == "new-refresh"
      assert refreshed.scopes == ["scope.from.grant"]
    end

    test "refresh_grant keeps existing oauth2 refresh_token when payload omits it" do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "cfg-refresh-missing-refresh-#{System.unique_integer([:positive])}",
        provider: "google_drive",
        kind: "data_source",
        enabled: true,
        settings: %{}
      })
      |> Repo.insert!()

      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        google_drive: %{bridge: StubOAuthMissingRefreshToken}
      })

      on_exit(fn ->
        if original_channels do
          Application.put_env(:zaq, :channels, original_channels)
        else
          Application.delete_env(:zaq, :channels)
        end
      end)

      {:ok, credential} =
        Connect.create_credential(%{
          name: "Missing refresh payload credential",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "secret",
          scopes: ["scope.from.credential"]
        })

      {:ok, grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "mcp",
          resource_id: "missing-refresh-response",
          owner_type: "org",
          metadata: %{},
          access_token: "old-access",
          refresh_token: "old-refresh",
          scopes: ["scope.from.grant"]
        })

      assert {:ok, refreshed} = Connect.refresh_grant(grant)
      assert refreshed.access_token == "new-access"
      assert refreshed.refresh_token == "old-refresh"
      assert refreshed.scopes == ["scope.from.refresh"]
    end
  end

  describe "credential operations" do
    test "preserves original refresh_token when token_payload lacks one" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "String Date Grant",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "secret",
          token_url: "https://oauth.example/token",
          scopes: ["scope.read"]
        })

      {:ok, grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "mcp",
          resource_id: "str-token",
          owner_type: "org",
          metadata: %{},
          access_token: "original-access",
          refresh_token: "original-refresh"
        })

      updated_grant = Repo.get!(Grant, grant.id)
      assert updated_grant.access_token == "original-access"
      assert updated_grant.refresh_token == "original-refresh"
    end

    test "next_refresh_jobs_for_grants with available future-scheduled job finds it" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Next refresh test credential",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "secret"
        })

      grant = issue_oauth_grant(credential)

      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _job} =
        Repo.insert(%Oban.Job{
          queue: "default",
          worker: to_string(GrantRefreshWorker),
          args: %{"grant_id" => grant.id},
          state: "available",
          scheduled_at: future
        })

      schedule = Connect.next_refresh_jobs_for_grants([grant])

      assert not is_nil(schedule[grant.id])
    end

    test "next_refresh_jobs_for_grants ignores past jobs and picks earliest candidate" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "Scheduler filter credential",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "id",
          client_secret: "secret"
        })

      grant = issue_oauth_grant(credential)

      now = DateTime.utc_now()
      past = DateTime.add(now, -30, :second)
      early = DateTime.add(now, 30, :second)
      late = DateTime.add(now, 120, :second)

      {:ok, _} =
        Repo.insert(%Oban.Job{
          queue: "default",
          worker: to_string(GrantRefreshWorker),
          args: %{"grant_id" => grant.id},
          state: "scheduled",
          scheduled_at: past
        })

      {:ok, _} =
        Repo.insert(%Oban.Job{
          queue: "default",
          worker: to_string(GrantRefreshWorker),
          args: %{"grant_id" => grant.id},
          state: "retryable",
          scheduled_at: late
        })

      {:ok, _} =
        Repo.insert(%Oban.Job{
          queue: "default",
          worker: to_string(GrantRefreshWorker),
          args: %{"grant_id" => grant.id},
          state: "available",
          scheduled_at: early
        })

      schedule = Connect.next_refresh_jobs_for_grants([grant])
      assert schedule[grant.id]
      assert DateTime.compare(schedule[grant.id], early) == :eq
    end
  end
end
