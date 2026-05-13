defmodule Zaq.Engine.ConnectTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}

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
  end
end
