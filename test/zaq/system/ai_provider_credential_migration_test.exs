defmodule Zaq.System.AIProviderCredentialMigrationTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Engine.Connect
  alias Zaq.System
  alias Zaq.System.AIProviderCredentialMigration
  alias Zaq.System.SecretConfig

  test "classifies explicit API-key, no-auth and unresolved credentials without secrets" do
    {:ok, api} = ai_credential(%{name: unique("api"), api_key: "do-not-report"})
    {:ok, none} = ai_credential(%{name: unique("none"), auth_kind: "none"})
    {:ok, missing} = ai_credential(%{name: unique("missing"), auth_kind: "none"})
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
    assert projected[missing.id].classification == :no_auth
    refute inspect(items) =~ "do-not-report"
  end

  test "classifies exactly one legacy OAuth grant and rejects ambiguous sets" do
    {:ok, ai} = ai_credential(%{name: unique("oauth"), auth_kind: "none"})
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
    {:ok, first} = ai_credential(%{name: unique("first"), auth_kind: "none"})
    {:ok, second} = ai_credential(%{name: unique("second"), auth_kind: "none"})

    assert {:ok, %{items: [item], next_after_id: next}} =
             AIProviderCredentialMigration.preflight(after_id: first.id - 1, limit: 1)

    assert item.ai_provider_credential_id == first.id
    assert next == first.id

    assert {:ok, %{items: [item]}} =
             AIProviderCredentialMigration.preflight(after_id: next, limit: 1)

    assert item.ai_provider_credential_id == second.id
    assert {:error, :invalid_options} = AIProviderCredentialMigration.preflight(limit: 0)
  end

  test "rejects non-list preflight options" do
    for input <- [nil, %{}, %{limit: 1}, :invalid, "limit=1", 1, {:limit, 1}] do
      assert AIProviderCredentialMigration.preflight(input) == {:error, :invalid_options},
             "input: #{inspect(input)}"
    end
  end

  test "treats non-map legacy metadata as missing explicit authentication" do
    {:ok, ai} =
      ai_credential(%{name: unique("invalid-metadata"), auth_kind: "none"})

    for metadata <- [nil, [], "none", false, 42] do
      assert AIProviderCredentialMigration.classify_legacy_row([ai.id, nil, metadata, nil]) == %{
               ai_provider_credential_id: ai.id,
               classification: :missing_auth,
               reason: :no_explicit_authentication,
               source_grant_id: nil,
               source_connect_credential_id: nil
             },
             "metadata: #{inspect(metadata)}"
    end

    assert AIProviderCredentialMigration.classify_legacy_row([
             ai.id,
             nil,
             %{"auth_kind" => "none"},
             nil
           ]) == %{
             ai_provider_credential_id: ai.id,
             classification: :no_auth,
             reason: nil,
             source_grant_id: nil,
             source_connect_credential_id: nil
           }
  end

  property "non-map legacy metadata never grants no-auth" do
    {:ok, ai} =
      ai_credential(%{
        name: unique("property-invalid-metadata"),
        auth_kind: "none"
      })

    check all(
            metadata <-
              one_of([
                constant(nil),
                boolean(),
                integer(),
                binary(),
                list_of(integer(), max_length: 4)
              ]),
            max_runs: 25
          ) do
      assert AIProviderCredentialMigration.classify_legacy_row([ai.id, nil, metadata, nil]) == %{
               ai_provider_credential_id: ai.id,
               classification: :missing_auth,
               reason: :no_explicit_authentication,
               source_grant_id: nil,
               source_connect_credential_id: nil
             }
    end
  end

  test "distinguishes blank and unreadable legacy API-key ciphertext without reporting secrets" do
    {:ok, blank} = SecretConfig.encrypt("   ")

    blank_item = AIProviderCredentialMigration.classify_legacy_row([101, blank, %{}, nil])

    unreadable_item =
      AIProviderCredentialMigration.classify_legacy_row([102, "enc:v1:malformed", %{}, nil])

    assert blank_item.classification == :no_auth
    assert blank_item.reason == nil
    assert unreadable_item.classification == :unreadable
    assert unreadable_item.reason == :api_key_decryption_failed
    refute inspect([blank_item, unreadable_item]) =~ "malformed"
  end

  test "classifies invalid legacy API-key storage without reporting the raw value" do
    {:ok, ai} = ai_credential(%{name: unique("invalid-key-storage"), auth_kind: "none"})

    item = AIProviderCredentialMigration.classify_legacy_row([ai.id, 42, %{}, nil])

    assert item == %{
             ai_provider_credential_id: ai.id,
             classification: :unreadable,
             reason: :invalid_api_key_storage,
             source_grant_id: nil,
             source_connect_credential_id: nil
           }

    refute 42 in Map.values(item)
  end

  test "unsupported auth kinds remain missing auth for keyless and blank-key rows" do
    {:ok, encrypted_blank} = SecretConfig.encrypt(" \n\t ")

    rows = [
      {nil, %{"auth_kind" => "jwt_bearer"}},
      {"", %{"auth_kind" => "jwt_bearer"}},
      {encrypted_blank, %{auth_kind: "jwt_bearer"}}
    ]

    for {raw, metadata} <- rows do
      {:ok, ai} = ai_credential(%{name: unique("unsupported-auth-kind"), auth_kind: "none"})

      assert AIProviderCredentialMigration.classify_legacy_row([ai.id, raw, metadata, nil]) == %{
               ai_provider_credential_id: ai.id,
               classification: :missing_auth,
               reason: :unsupported_auth_kind,
               source_grant_id: nil,
               source_connect_credential_id: nil
             }
    end
  end

  test "keyless legacy API-key rows migrate without guessing away incomplete OAuth intent" do
    for raw <- [nil, ""] do
      assert %{classification: :no_auth} =
               AIProviderCredentialMigration.classify_legacy_row([101, raw, %{}, nil])

      assert %{classification: :missing_auth} =
               AIProviderCredentialMigration.classify_legacy_row([
                 101,
                 raw,
                 %{"auth_kind" => "oauth2"},
                 nil
               ])
    end

    {:ok, blank} = SecretConfig.encrypt(" \n\t ")

    assert %{classification: :no_auth} =
             AIProviderCredentialMigration.classify_legacy_row([101, blank, %{}, nil])

    assert %{classification: :missing_auth} =
             AIProviderCredentialMigration.classify_legacy_row([
               101,
               blank,
               %{"auth_profile" => "openai_chatgpt_codex"},
               nil
             ])

    assert %{classification: :missing_auth, reason: :incomplete_oauth} =
             AIProviderCredentialMigration.classify_legacy_row([
               101,
               nil,
               %{"client_id" => "oauth-client"},
               nil
             ])

    assert %{classification: :missing_auth, reason: :incomplete_oauth} =
             AIProviderCredentialMigration.classify_legacy_row([
               101,
               nil,
               %{},
               nil,
               "openai_codex"
             ])
  end

  property "readable whitespace-only legacy keys are no-auth, never usable API keys" do
    check all(
            chars <- list_of(member_of([" ", "\t", "\n", "\r"]), min_length: 1, max_length: 16),
            max_runs: 18
          ) do
      {:ok, encrypted} = SecretConfig.encrypt(Enum.join(chars))

      assert %{classification: :no_auth, reason: nil} =
               AIProviderCredentialMigration.classify_legacy_row([101, encrypted, %{}, nil])
    end
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
