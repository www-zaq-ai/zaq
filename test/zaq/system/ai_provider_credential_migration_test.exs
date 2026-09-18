defmodule Zaq.System.AIProviderCredentialMigrationTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Connect
  alias Zaq.System
  alias Zaq.System.AIProviderCredentialMigration
  alias Zaq.System.SecretConfig

  test "classifies explicit API-key, no-auth and unresolved credentials without secrets" do
    {:ok, api} = ai_credential(%{name: unique("api"), api_key: "do-not-report"})
    {:ok, none} = ai_credential(%{name: unique("none"), metadata: %{"auth_kind" => "none"}})
    {:ok, missing} = ai_credential(%{name: unique("missing"), metadata: %{"auth_kind" => "none"}})
    {:ok, encrypted} = SecretConfig.encrypt("do-not-report")

    items = [
      AIProviderCredentialMigration.classify_legacy_row([api.id, encrypted, %{}, nil]),
      AIProviderCredentialMigration.classify_legacy_row([
        none.id,
        nil,
        %{"auth_kind" => "none"},
        nil
      ]),
      AIProviderCredentialMigration.classify_legacy_row([missing.id, nil, %{}, nil])
    ]

    projected = Map.new(items, &{&1.ai_provider_credential_id, &1})
    assert projected[api.id].classification == :api_key
    assert projected[none.id].classification == :no_auth
    assert projected[missing.id].classification == :missing_auth
    refute inspect(items) =~ "do-not-report"
  end

  test "classifies exactly one legacy OAuth grant and rejects ambiguous sets" do
    {:ok, ai} = ai_credential(%{name: unique("oauth"), metadata: %{"auth_kind" => "none"}})
    c1 = oauth_credential(unique("connect"))
    grant = legacy_oauth_grant(c1, ai.id)

    item = AIProviderCredentialMigration.classify_legacy_row([ai.id, nil, %{}, nil])

    assert item.classification == :oauth2
    assert item.source_grant_id == grant.id
    assert item.source_connect_credential_id == c1.id

    c2 = oauth_credential(unique("connect"))
    legacy_oauth_grant(c2, ai.id)

    item = AIProviderCredentialMigration.classify_legacy_row([ai.id, nil, %{}, nil])

    assert item.classification == :ambiguous
  end

  test "uses bounded keyset pagination and validates options" do
    {:ok, first} = ai_credential(%{name: unique("first"), metadata: %{"auth_kind" => "none"}})
    {:ok, second} = ai_credential(%{name: unique("second"), metadata: %{"auth_kind" => "none"}})

    assert {:ok, %{items: [item], next_after_id: next}} =
             AIProviderCredentialMigration.preflight(after_id: first.id - 1, limit: 1)

    assert item.ai_provider_credential_id == first.id
    assert next == first.id

    assert {:ok, %{items: [item]}} =
             AIProviderCredentialMigration.preflight(after_id: next, limit: 1)

    assert item.ai_provider_credential_id == second.id
    assert {:error, :invalid_options} = AIProviderCredentialMigration.preflight(limit: 0)
  end

  test "distinguishes blank and unreadable legacy API-key ciphertext without reporting secrets" do
    {:ok, blank} = SecretConfig.encrypt("   ")

    blank_item = AIProviderCredentialMigration.classify_legacy_row([101, blank, %{}, nil])

    unreadable_item =
      AIProviderCredentialMigration.classify_legacy_row([102, "enc:v1:malformed", %{}, nil])

    assert blank_item.classification == :missing_auth
    assert blank_item.reason == :blank_api_key
    assert unreadable_item.classification == :unreadable
    assert unreadable_item.reason == :api_key_decryption_failed
    refute inspect([blank_item, unreadable_item]) =~ "malformed"
  end

  defp ai_credential(attrs) do
    System.create_ai_provider_credential(
      Map.merge(%{provider: "openai", endpoint: "https://example.test/v1"}, attrs)
    )
  end

  defp oauth_credential(name) do
    {:ok, credential} =
      Connect.create_credential(%{
        name: name,
        provider: "openai",
        auth_kind: "oauth2",
        client_id: "client-id",
        request_format: "bearer",
        user_level: false,
        metadata: %{}
      })

    credential
  end

  defp legacy_oauth_grant(credential, ai_id) do
    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "ai_provider_credential",
        resource_id: ai_id,
        owner_type: "org",
        metadata: %{},
        access_token: "token",
        refresh_token: "refresh"
      })

    grant
  end

  defp unique(prefix), do: "#{prefix}-#{:erlang.unique_integer([:positive])}"
end
