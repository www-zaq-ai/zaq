defmodule Zaq.UserPortal.ProvisionerTest do
  use Zaq.DataCase, async: false

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
      assert System.get_llm_config().model == "owl-alpha"

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
end
