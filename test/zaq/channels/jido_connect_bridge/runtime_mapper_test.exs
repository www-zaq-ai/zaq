defmodule Zaq.Channels.JidoConnectBridge.RuntimeMapperTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.JidoConnectBridge.RuntimeMapper
  alias Zaq.Engine.Connect.{Credential, Grant}

  # ── to_connection/1 ──────────────────────────────────────────────────

  describe "to_connection/1" do
    test "builds a Connection from a full Grant" do
      grant =
        build_grant(%{
          id: 42,
          provider: "google_drive",
          auth_kind: "oauth2",
          owner_type: "user",
          owner_id: 7,
          credential_id: 99,
          scopes: ["read", "write"],
          metadata: %{org: "acme"}
        })

      conn = RuntimeMapper.to_connection(grant)

      assert conn.id == "grant:42"
      assert conn.provider == :google_drive
      assert conn.profile == :oauth2
      assert conn.tenant_id == "zaq"
      assert conn.owner_type == :user
      assert conn.owner_id == "7"
      assert conn.subject == %{}
      assert conn.status == :connected
      assert conn.credential_ref == "credential:99"
      assert conn.scopes == ["read", "write"]
      assert conn.metadata == %{org: "acme"}
    end

    test "normalizes nil owner_id to org" do
      grant = build_grant(%{owner_id: nil})

      conn = RuntimeMapper.to_connection(grant)

      assert conn.owner_id == "org"
    end

    test "converts integer owner_id to string" do
      grant = build_grant(%{owner_id: 123})

      conn = RuntimeMapper.to_connection(grant)

      assert conn.owner_id == "123"
    end

    test "defaults nil scopes to empty list" do
      grant = build_grant(%{scopes: nil})

      conn = RuntimeMapper.to_connection(grant)

      assert conn.scopes == []
    end

    test "defaults nil metadata to empty map" do
      grant = build_grant(%{metadata: nil})

      conn = RuntimeMapper.to_connection(grant)

      assert conn.metadata == %{}
    end

    test "preserves empty scopes" do
      grant = build_grant(%{scopes: []})

      conn = RuntimeMapper.to_connection(grant)

      assert conn.scopes == []
    end

    test "preserves empty metadata" do
      grant = build_grant(%{metadata: %{}})

      conn = RuntimeMapper.to_connection(grant)

      assert conn.metadata == %{}
    end

    test "converts owner_type atom correctly" do
      grant = build_grant(%{owner_type: "org"})

      conn = RuntimeMapper.to_connection(grant)

      assert conn.owner_type == :org
    end
  end

  # ── to_credential_lease/2 ────────────────────────────────────────────

  describe "to_credential_lease/2" do
    test "builds oauth2 credential lease with tokens" do
      grant =
        build_grant(%{
          auth_kind: "oauth2",
          access_token: "at-1",
          refresh_token: "rt-1",
          scopes: ["read"]
        })

      credential = build_credential(%{})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert lease.fields.access_token == "at-1"
      assert lease.fields.refresh_token == "rt-1"
      assert lease.scopes == ["read"]
      assert lease.connection_id == "grant:#{grant.id}"
    end

    test "oauth2 defaults nil scopes to empty list in fields" do
      grant =
        build_grant(%{
          auth_kind: "oauth2",
          access_token: "at-1",
          refresh_token: "rt-1",
          scopes: nil
        })

      credential = build_credential(%{})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert lease.fields.scopes == []
    end

    test "api_key uses grant api_key when present" do
      grant =
        build_grant(%{
          auth_kind: "api_key",
          api_key: "grant-key"
        })

      credential = build_credential(%{api_key: "cred-key"})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert lease.fields.api_key == "grant-key"
    end

    test "api_key falls back to credential api_key when grant api_key is nil" do
      grant =
        build_grant(%{
          auth_kind: "api_key",
          api_key: nil
        })

      credential = build_credential(%{api_key: "cred-fallback-key"})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert lease.fields.api_key == "cred-fallback-key"
    end

    test "api_key falls back to credential api_key when grant api_key is missing" do
      grant =
        build_grant(%{
          auth_kind: "api_key",
          api_key: nil
        })

      credential = build_credential(%{api_key: "another-key"})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert lease.fields.api_key == "another-key"
    end

    test "sets default expires_at when grant expires_at is nil" do
      grant =
        build_grant(%{
          auth_kind: "oauth2",
          access_token: "at-1",
          expires_at: nil
        })

      credential = build_credential(%{})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert DateTime.compare(lease.expires_at, DateTime.utc_now()) == :gt
    end

    test "preserves grant expires_at when present" do
      future = DateTime.add(DateTime.utc_now(), 7200, :second)

      grant =
        build_grant(%{
          auth_kind: "oauth2",
          access_token: "at-1",
          expires_at: future
        })

      credential = build_credential(%{})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert lease.expires_at == future
    end

    test "defaults nil grant metadata" do
      grant =
        build_grant(%{
          auth_kind: "oauth2",
          access_token: "at-1",
          metadata: nil
        })

      credential = build_credential(%{})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert lease.metadata == %{}
    end

    test "preserves grant metadata when present" do
      grant =
        build_grant(%{
          auth_kind: "oauth2",
          access_token: "at-1",
          metadata: %{region: "us-east"}
        })

      credential = build_credential(%{})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert lease.metadata == %{region: "us-east"}
    end

    test "builds api_key credential lease with correct connection_id" do
      grant =
        build_grant(%{
          id: 77,
          auth_kind: "api_key",
          api_key: "k-abc"
        })

      credential = build_credential(%{})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert lease.fields.api_key == "k-abc"
      assert lease.connection_id == "grant:77"
    end

    test "builds jwt_bearer credential lease with connector-compatible keys" do
      grant =
        build_grant(%{
          id: 88,
          auth_kind: "jwt_bearer",
          access_token: "jwt-access-token",
          scopes: ["https://www.googleapis.com/auth/drive.readonly"],
          issuer: "svc@example.iam.gserviceaccount.com",
          private_key: "-----BEGIN PRIVATE KEY-----x",
          key_id: "kid-1"
        })

      credential = build_credential(%{})

      lease = RuntimeMapper.to_credential_lease(grant, credential)

      assert lease.fields.access_token == "jwt-access-token"
      assert lease.fields.scopes == ["https://www.googleapis.com/auth/drive.readonly"]
      assert lease.fields.issuer == "svc@example.iam.gserviceaccount.com"
      assert lease.fields.client_email == "svc@example.iam.gserviceaccount.com"
      assert lease.fields.private_key == "-----BEGIN PRIVATE KEY-----x"
      assert lease.fields.key_id == "kid-1"
      assert lease.fields.private_key_id == "kid-1"
      assert lease.connection_id == "grant:88"
    end

    test "prefers metadata auth_profile_id when building connection profile" do
      grant =
        build_grant(%{
          auth_kind: "jwt_bearer",
          metadata: %{"auth_profile_id" => "domain_delegated_service_account"}
        })

      conn = RuntimeMapper.to_connection(grant)

      assert conn.profile == :domain_delegated_service_account
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp build_grant(overrides) do
    default = %{
      id: 1,
      credential_id: 1,
      provider: "test_provider",
      auth_kind: "oauth2",
      resource_type: "data_source",
      resource_id: "res-1",
      owner_type: "user",
      owner_id: 1,
      request_format: "bearer",
      metadata: %{},
      status: "active",
      access_token: nil,
      refresh_token: nil,
      scopes: [],
      api_key: nil,
      issuer: nil,
      private_key: nil,
      key_id: nil,
      subject: nil,
      expires_at: nil,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(Grant, Map.merge(default, overrides))
  end

  defp build_credential(overrides) do
    default = %{
      id: 1,
      name: "test-cred",
      provider: "test_provider",
      auth_kind: "oauth2",
      user_level: false,
      request_format: "bearer",
      metadata: %{},
      client_id: nil,
      client_secret: nil,
      scopes: [],
      issuer: nil,
      private_key: nil,
      key_id: nil,
      api_key: nil,
      expires_at: nil,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(Credential, Map.merge(default, overrides))
  end
end
