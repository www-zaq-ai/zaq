defmodule Zaq.Engine.ConnectTest do
  use Zaq.DataCase, async: true

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Engine.Connect.GrantRefreshWorker
  alias Zaq.Repo
  alias Zaq.Types.EncryptedString

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
  end

  describe "grants" do
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

    test "resolves latest active grant for owner and resource context" do
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

    test "issue_grant rejects provider mismatch for data source resource" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "OAuth2 Config",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "client-id",
          client_secret: "secret"
        })

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

    test "revoke_grant sets grant status to revoked" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "OAuth2 Config",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "client-id",
          client_secret: "secret"
        })

      {:ok, grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "12",
          owner_type: "org",
          metadata: %{},
          access_token: "a",
          refresh_token: "r"
        })

      assert {:ok, revoked} = Connect.revoke_grant(grant)
      assert revoked.status == "revoked"
    end

    test "next_refresh_jobs_for_grants returns map with nil when no jobs" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "OAuth2 Config",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "client-id",
          client_secret: "secret"
        })

      {:ok, grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "22",
          owner_type: "org",
          metadata: %{},
          access_token: "a",
          refresh_token: "r"
        })

      schedule = Connect.next_refresh_jobs_for_grants([grant])
      assert Map.get(schedule, grant.id) == nil
    end

    test "schedule_refresh enqueues oban job" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "OAuth2 Config",
          provider: "google_drive",
          auth_kind: "oauth2",
          request_format: "bearer",
          user_level: false,
          metadata: %{},
          client_id: "client-id",
          client_secret: "secret"
        })

      {:ok, grant} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "data_source",
          resource_id: "23",
          owner_type: "org",
          metadata: %{},
          access_token: "a",
          refresh_token: "r"
        })

      assert {:ok, job} = Connect.schedule_refresh(grant)
      assert job.worker == "Zaq.Engine.Connect.GrantRefreshWorker"
    end
  end
end
