defmodule Zaq.UserPortal.ProvisionerTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Api
  alias Zaq.Event
  alias Zaq.System
  alias Zaq.UserPortal.Provisioner

  defmodule EngineRouter do
    def dispatch(%Event{} = event) do
      send(self(), {:engine_event, event})
      Api.handle_event(event, event.opts[:action], nil)
    end
  end

  defmodule UnavailableEngineRouter do
    def dispatch(%Event{} = event),
      do: %{event | response: {:error, {:service_unavailable, :engine}}}
  end

  describe "provision_with_key/1" do
    test "routes secret-bearing create and update mutations through Engine" do
      opts = [node_router_module: EngineRouter]

      assert {:ok, credential} =
               Provisioner.provision_with_key(%{litellm_api_key: "sk-routed-create"}, opts)

      assert_received {:engine_event, create_event}
      assert create_event.next_hop.destination == :engine
      assert create_event.opts[:action] == :system_config_create_ai_provider_credential
      assert create_event.opts[:confidential] == true
      assert create_event.actor == %{kind: :system, subject: "user-portal-provisioner"}

      assert {:ok, updated} =
               Provisioner.provision_with_key(%{litellm_api_key: "sk-routed-update"}, opts)

      assert updated.id == credential.id
      assert_received {:engine_event, update_event}
      assert update_event.opts[:action] == :system_config_update_ai_provider_credential
      assert update_event.opts[:confidential] == true
    end

    test "propagates Engine unavailability without local persistence" do
      assert Provisioner.provision_with_key(
               %{litellm_api_key: "sk-unavailable"},
               node_router_module: UnavailableEngineRouter
             ) == {:error, {:service_unavailable, :engine}}

      assert System.get_ai_provider_credential_by_name(Provisioner.credential_name()) == nil
    end

    test "creates a new ZAQ Router credential when none exists" do
      assert {:ok, credential} = Provisioner.provision_with_key(%{litellm_api_key: "sk-new"})
      credential = System.get_ai_provider_credential!(credential.id)

      assert credential.name == "ZAQ Router"
      assert credential.provider == "zaq_router"
      assert credential.api_key == "sk-new"
    end

    test "updates an existing ZAQ Router credential" do
      assert {:ok, credential} = Provisioner.provision_with_key(%{litellm_api_key: "sk-existing"})

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

      assert System.get_image_to_text_config().model ==
               "nvidia/nemotron-nano-12b-v2-vl"
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

  describe "ensure_offline_credential/0" do
    test "creates a keyless ZAQ Router credential without wiring model configs" do
      assert {:ok, credential} = Provisioner.ensure_offline_credential()
      credential = System.get_ai_provider_credential!(credential.id)

      assert credential.name == "ZAQ Router"
      assert credential.provider == "zaq_router"
      assert is_nil(credential.api_key)

      # Provider is listed, but not set as the active model configuration.
      assert is_nil(System.get_llm_config().credential_id)
      assert is_nil(System.get_embedding_config().credential_id)
      assert is_nil(System.get_image_to_text_config().credential_id)
    end

    test "does not overwrite an existing credential or its key" do
      assert {:ok, existing} = Provisioner.provision_with_key(%{litellm_api_key: "sk-keep"})

      assert {:ok, same} = Provisioner.ensure_offline_credential()

      assert same.id == existing.id
      assert System.get_ai_provider_credential!(same.id).api_key == "sk-keep"
    end
  end
end
