defmodule Zaq.Engine.Connect.GrantTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Connect.Grant

  test "requires access_token for oauth2 grants" do
    changeset =
      Grant.changeset(%Grant{}, %{
        credential_id: 1,
        provider: "google_drive",
        auth_kind: "oauth2",
        resource_type: "data_source",
        resource_id: "123",
        owner_type: "org",
        request_format: "bearer",
        metadata: %{},
        status: "active"
      })

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).access_token
  end

  test "requires api_key for api_key grants" do
    changeset =
      Grant.changeset(%Grant{}, %{
        credential_id: 1,
        provider: "google_drive",
        auth_kind: "api_key",
        resource_type: "mcp",
        resource_id: "endpoint-1",
        owner_type: "user",
        owner_id: 12,
        request_format: "raw",
        metadata: %{},
        status: "active"
      })

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).api_key
  end

  test "validates enum-like inclusions" do
    changeset =
      Grant.changeset(%Grant{}, %{
        credential_id: 1,
        provider: "google_drive",
        auth_kind: "something_else",
        resource_type: "unknown",
        resource_id: "123",
        owner_type: "neither",
        request_format: "json",
        metadata: %{},
        status: "pending"
      })

    refute changeset.valid?
    errors = errors_on(changeset)
    assert "is invalid" in errors.auth_kind
    assert "is invalid" in errors.resource_type
    assert "is invalid" in errors.owner_type
    assert "is invalid" in errors.request_format
    assert "is invalid" in errors.status
  end

  test "requires issuer, private_key and key_id for jwt_bearer grants" do
    changeset =
      Grant.changeset(%Grant{}, %{
        credential_id: 1,
        provider: "google_drive",
        auth_kind: "jwt_bearer",
        resource_type: "data_source",
        resource_id: "123",
        owner_type: "org",
        request_format: "bearer",
        metadata: %{},
        status: "active"
      })

    refute changeset.valid?
    errors = errors_on(changeset)
    assert "can't be blank" in errors.issuer
    assert "can't be blank" in errors.private_key
    assert "can't be blank" in errors.key_id
  end

  test "allows ai_provider_credential grants for oauth2 auth" do
    changeset =
      Grant.changeset(%Grant{}, %{
        credential_id: 1,
        provider: "openai",
        auth_kind: "oauth2",
        resource_type: "ai_provider_credential",
        resource_id: "123",
        owner_type: "org",
        request_format: "bearer",
        metadata: %{"auth_profile" => "openai_chatgpt_codex"},
        status: "active",
        access_token: "bearer-token",
        refresh_token: "refresh-token",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    assert changeset.valid?
  end

  test "rejects removed ai auth kinds" do
    changeset =
      Grant.changeset(%Grant{}, %{
        credential_id: 1,
        provider: "openai",
        auth_kind: "removed_kind",
        resource_type: "ai_provider_credential",
        resource_id: "123",
        owner_type: "org",
        request_format: "bearer",
        metadata: %{},
        status: "active"
      })

    refute changeset.valid?
    assert "is invalid" in errors_on(changeset).auth_kind
  end

  test "validates required fields" do
    changeset = Grant.changeset(%Grant{}, %{})

    refute changeset.valid?
    errors = errors_on(changeset)
    assert "can't be blank" in errors.credential_id
    assert "can't be blank" in errors.provider
    assert "can't be blank" in errors.auth_kind
    assert "can't be blank" in errors.resource_type
    assert "can't be blank" in errors.resource_id
    assert "can't be blank" in errors.owner_type
    assert is_nil(Map.get(errors, :request_format))
    assert is_nil(Map.get(errors, :status))
  end
end
