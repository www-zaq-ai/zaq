defmodule Zaq.System.AIProviderCredentialTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Connect
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.System.AIProviderCredential

  setup do
    prev_secret = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

    Application.put_env(:zaq, Zaq.System.SecretConfig,
      encryption_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      key_id: "test-v1"
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.System.SecretConfig, prev_secret)
    end)

    :ok
  end

  test "creates, lists, gets and deletes AI provider credentials" do
    unique = :erlang.unique_integer([:positive])

    assert {:ok, %AIProviderCredential{} = credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI EU #{unique}",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               sovereign: true,
               description: "EU sovereign endpoint"
             })

    assert Enum.any?(System.list_ai_provider_credentials(), &(&1.id == credential.id))
    assert %AIProviderCredential{id: id} = System.get_ai_provider_credential!(credential.id)
    assert id == credential.id

    assert {:ok, _} = System.delete_ai_provider_credential(credential)
    refute Enum.any?(System.list_ai_provider_credentials(), &(&1.id == credential.id))
  end

  test "stores metadata for OpenAI Codex OAuth2 configuration" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI Codex Metadata",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               metadata: %{
                 "auth_kind" => "oauth2",
                 "auth_profile" => "openai_chatgpt_codex"
               }
             })

    loaded = System.get_ai_provider_credential!(credential.id)
    assert loaded.metadata["auth_kind"] == "oauth2"
    assert loaded.metadata["auth_profile"] == "openai_chatgpt_codex"
  end

  test "create_ai_provider_credential/0 returns an invalid changeset error" do
    assert {:error, %Ecto.Changeset{} = changeset} = System.create_ai_provider_credential()
    assert "can't be blank" in errors_on(changeset).name
    assert "can't be blank" in errors_on(changeset).provider
    assert "can't be blank" in errors_on(changeset).endpoint
  end

  test "change_ai_provider_credential/1 returns a base changeset" do
    changeset = System.change_ai_provider_credential(%AIProviderCredential{})
    assert %Ecto.Changeset{} = changeset
    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).name
  end

  test "stores api_key encrypted in DB and returns decrypted value" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "Anthropic",
               provider: "anthropic",
               endpoint: "https://api.anthropic.com/v1",
               api_key: "sk-credential-secret"
             })

    [[raw_api_key]] =
      Repo.query!("SELECT api_key FROM ai_provider_credentials WHERE id = $1", [credential.id]).rows

    assert String.starts_with?(raw_api_key, "enc:")

    loaded = System.get_ai_provider_credential!(credential.id)
    assert loaded.api_key == "sk-credential-secret"
  end

  test "returns changeset error when api_key encryption key is invalid" do
    prev = Application.get_env(:zaq, Zaq.System.SecretConfig)

    Application.put_env(:zaq, Zaq.System.SecretConfig,
      encryption_key: "invalid",
      key_id: "test-v1"
    )

    try do
      assert {:error, %Ecto.Changeset{} = changeset} =
               System.create_ai_provider_credential(%{
                 name: "Failing",
                 provider: "openai",
                 endpoint: "https://api.openai.com/v1",
                 api_key: "must-fail"
               })

      assert hd(errors_on(changeset).api_key) =~ "could not be encrypted"
    after
      Application.put_env(:zaq, Zaq.System.SecretConfig, prev)
    end
  end

  test "returns specific changeset error when api_key encryption key is missing" do
    prev = Application.get_env(:zaq, Zaq.System.SecretConfig)
    Application.put_env(:zaq, Zaq.System.SecretConfig, [])

    try do
      assert {:error, %Ecto.Changeset{} = changeset} =
               System.create_ai_provider_credential(%{
                 name: "Failing Missing Key",
                 provider: "openai",
                 endpoint: "https://api.openai.com/v1",
                 api_key: "must-fail"
               })

      assert hd(errors_on(changeset).api_key) =~ "missing SYSTEM_CONFIG_ENCRYPTION_KEY"
    after
      Application.put_env(:zaq, Zaq.System.SecretConfig, prev)
    end
  end

  test "blank api_key update preserves previously stored key" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "Reusable",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               api_key: "first-secret"
             })

    assert {:ok, _} =
             System.update_ai_provider_credential(credential, %{
               name: "Reusable",
               provider: "openai",
               endpoint: "https://api.openai.com/v2",
               api_key: ""
             })

    loaded = System.get_ai_provider_credential!(credential.id)
    assert loaded.api_key == "first-secret"
    assert loaded.endpoint == "https://api.openai.com/v2"
  end

  test "blank api_key update preserves key for string-key attrs" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "Reusable String",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               api_key: "first-secret-string"
             })

    assert {:ok, _} =
             System.update_ai_provider_credential(credential, %{
               "name" => "Reusable String",
               "provider" => "openai",
               "endpoint" => "https://api.openai.com/v3",
               "api_key" => ""
             })

    loaded = System.get_ai_provider_credential!(credential.id)
    assert loaded.api_key == "first-secret-string"
    assert loaded.endpoint == "https://api.openai.com/v3"
  end

  test "resolve_ai_provider_api_key prefers stored api key over connect grant" do
    assert {:ok, ai_credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI API Key Preferred",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               api_key: "sk-preferred"
             })

    connect_credential = create_connect_token_credential("openai")
    issue_connect_ai_grant(connect_credential, ai_credential, "grant-token")

    assert System.resolve_ai_provider_api_key(
             System.get_ai_provider_credential!(ai_credential.id)
           ) ==
             "sk-preferred"
  end

  test "resolve_ai_provider_api_key falls back to active connect bearer token" do
    assert {:ok, ai_credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI Bearer Fallback",
               provider: "openai",
               endpoint: "https://api.openai.com/v1"
             })

    connect_credential = create_connect_token_credential("openai")
    issue_connect_ai_grant(connect_credential, ai_credential, "grant-token")

    assert System.resolve_ai_provider_api_key(
             System.get_ai_provider_credential!(ai_credential.id)
           ) ==
             "grant-token"
  end

  test "resolve_ai_provider_api_key returns blank for missing connect grant" do
    assert {:ok, ai_credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI Missing Grant",
               provider: "openai",
               endpoint: "https://api.openai.com/v1"
             })

    assert System.resolve_ai_provider_api_key(
             System.get_ai_provider_credential!(ai_credential.id)
           ) == ""
  end

  test "cannot delete credential currently used by system configuration" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "In Use Credential",
               provider: "openai",
               endpoint: "https://api.openai.com/v1"
             })

    System.set_config("llm.credential_id", credential.id)

    assert {:error, %Ecto.Changeset{} = changeset} =
             System.delete_ai_provider_credential(credential)

    assert "cannot delete credential currently used by system configuration" in errors_on(
             changeset
           ).base

    id = credential.id
    assert %AIProviderCredential{id: ^id} = System.get_ai_provider_credential!(id)
  end

  defp create_connect_token_credential(provider) do
    unique = :erlang.unique_integer([:positive])

    {:ok, credential} =
      Connect.create_credential(%{
        name: "#{provider} Connect #{unique}",
        provider: provider,
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{"auth_profile" => "openai_chatgpt_codex"},
        client_id: "client-id"
      })

    credential
  end

  defp issue_connect_ai_grant(connect_credential, ai_credential, token) do
    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: connect_credential.id,
        resource_type: "ai_provider_credential",
        resource_id: ai_credential.id,
        owner_type: "org",
        metadata: %{},
        access_token: token,
        refresh_token: "refresh-token",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    grant
  end
end
