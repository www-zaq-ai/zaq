defmodule Zaq.System.AIProviderCredentialTest do
  use Zaq.DataCase, async: false

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
    assert {:ok, %AIProviderCredential{} = credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI EU",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               sovereign: true,
               description: "EU sovereign endpoint"
             })

    assert [%AIProviderCredential{id: id}] = System.list_ai_provider_credentials()
    assert id == credential.id
    assert %AIProviderCredential{id: ^id} = System.get_ai_provider_credential!(id)

    assert {:ok, _} = System.delete_ai_provider_credential(credential)
    assert [] == System.list_ai_provider_credentials()
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
    Application.put_env(:zaq, Zaq.System.SecretConfig,
      encryption_key: "invalid",
      key_id: "test-v1"
    )

    assert {:error, %Ecto.Changeset{} = changeset} =
             System.create_ai_provider_credential(%{
               name: "Failing",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               api_key: "must-fail"
             })

    assert hd(errors_on(changeset).api_key) =~ "could not be encrypted"
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
end
