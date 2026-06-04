defmodule Zaq.UserPortal.ProvisionerTest do
  use Zaq.DataCase, async: false

  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.UserPortal.Provisioner

  describe "provision_with_key/2" do
    test "creates a new ZAQ Provider credential when none exists" do
      assert {:ok, credential} = Provisioner.provision_with_key(%{litellm_api_key: "sk-new"})
      credential = System.get_ai_provider_credential!(credential.id)

      assert credential.name == "ZAQ Provider"
      assert credential.provider == "zaq_provider"
      assert credential.api_key == "sk-new"
    end

    test "updates an existing ZAQ Provider credential" do
      assert {:ok, credential} = Provisioner.provision_without_key()

      assert {:ok, updated} = Provisioner.provision_with_key(%{litellm_api_key: "sk-updated"})
      updated = System.get_ai_provider_credential!(updated.id)

      assert updated.id == credential.id
      assert updated.api_key == "sk-updated"
    end

    test "wires LLM, embedding, and image-to-text configs on first call" do
      assert {:ok, credential} = Provisioner.provision_with_key(%{litellm_api_key: "sk-config"})

      assert System.get_llm_config().credential_id == credential.id
      assert System.get_llm_config().model == "openai/gpt-oss-120b"

      assert System.get_embedding_config().credential_id == credential.id
      assert System.get_embedding_config().model == "nvidia/llama-nemotron-embed-vl-1b-v2"
      assert System.get_embedding_config().dimension == 2048

      assert System.get_image_to_text_config().credential_id == credential.id
      assert System.get_image_to_text_config().model == "google/gemma-4-31b-it"
    end

    test "does not overwrite existing configs on second call" do
      existing_llm = Zaq.SystemConfigFixtures.seed_llm_config(%{model: "existing-llm"})

      existing_embedding =
        Zaq.SystemConfigFixtures.seed_embedding_config(%{model: "existing-embed"})

      existing_image =
        Zaq.SystemConfigFixtures.seed_image_to_text_config(%{model: "existing-image"})

      assert {:ok, _credential} = Provisioner.provision_with_key(%{litellm_api_key: "sk-keep"})

      assert System.get_llm_config().credential_id == existing_llm.id
      assert System.get_llm_config().model == "existing-llm"
      assert System.get_embedding_config().credential_id == existing_embedding.id
      assert System.get_embedding_config().model == "existing-embed"
      assert System.get_image_to_text_config().credential_id == existing_image.id
      assert System.get_image_to_text_config().model == "existing-image"
    end
  end

  describe "provision_without_key/1" do
    test "creates credential with no api_key" do
      assert {:ok, credential} = Provisioner.provision_without_key()

      assert credential.name == "ZAQ Provider"
      assert credential.api_key == nil
    end

    test "does not touch system configs" do
      assert {:ok, _credential} = Provisioner.provision_without_key()

      assert System.get_llm_config().credential_id == nil
      assert System.get_embedding_config().credential_id == nil
      assert System.get_image_to_text_config().credential_id == nil
    end

    test "is idempotent when credential already exists" do
      assert {:ok, first} = Provisioner.provision_without_key()
      assert {:ok, second} = Provisioner.provision_without_key()

      assert second.id == first.id

      assert System.list_ai_provider_credentials() |> Enum.count(&(&1.name == "ZAQ Provider")) ==
               1
    end
  end

  describe "provision_for_existing_user/1" do
    setup do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        Req.Test.json(conn, %{
          "status" => "ok",
          "user" => %{
            "litellm_api_key" => "sk-test-key",
            "litellm_user_id" => "llm-user-test"
          }
        })
      end)

      :ok
    end

    test "provisions the portal and marks consent as accepted" do
      user =
        user_fixture(%{email: "portal@zaq.local"})
        |> set_portal_consent("declined")

      assert {:ok, updated_user} = Provisioner.provision_for_existing_user(user)

      assert updated_user.portal_consent == "accepted"
      assert Accounts.get_user!(user.id).portal_consent == "accepted"

      assert %Zaq.System.AIProviderCredential{name: "ZAQ Provider"} =
               System.get_ai_provider_credential_by_name("ZAQ Provider")
    end

    test "returns error when litellm credential creation fails" do
      prev_secret = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

      Application.put_env(:zaq, Zaq.System.SecretConfig,
        encryption_key: nil,
        key_id: "v1"
      )

      on_exit(fn -> Application.put_env(:zaq, Zaq.System.SecretConfig, prev_secret) end)

      user =
        user_fixture(%{email: "portal-error@zaq.local"})
        |> set_portal_consent("declined")

      assert {:error, %Ecto.Changeset{}} = Provisioner.provision_for_existing_user(user)
      assert Accounts.get_user!(user.id).portal_consent == "declined"
    end
  end

  defp set_portal_consent(%User{} = user, consent) do
    {:ok, user} =
      user
      |> User.portal_consent_changeset(consent)
      |> Repo.update()

    user
  end
end
