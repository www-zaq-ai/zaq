defmodule Zaq.Agent.ProviderSpecTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.ProviderSpec

  describe "reqllm_provider/1" do
    test "known native provider returns its catalog atom" do
      assert ProviderSpec.reqllm_provider("openai") == :openai
      assert ProviderSpec.reqllm_provider("anthropic") == :anthropic
    end

    test "unknown provider falls back to :openai" do
      assert ProviderSpec.reqllm_provider("totally_nonexistent_xyz") == :openai
    end

    test "catalog_only provider falls back to :openai" do
      catalog_only =
        LLMDB.providers()
        |> Enum.find(& &1.catalog_only)

      if catalog_only do
        assert ProviderSpec.reqllm_provider(to_string(catalog_only.id)) == :openai
      end
    end
  end

  describe "fixed_url_provider?/1" do
    test "returns true for known fixed-URL providers" do
      assert ProviderSpec.fixed_url_provider?(:anthropic) == true
      assert ProviderSpec.fixed_url_provider?(:google) == true
      assert ProviderSpec.fixed_url_provider?(:xai) == true
      assert ProviderSpec.fixed_url_provider?(:mistral) == true
    end

    test "returns false for user-configurable providers" do
      assert ProviderSpec.fixed_url_provider?(:openai) == false
    end

    test "accepts string provider names" do
      assert ProviderSpec.fixed_url_provider?("anthropic") == true
      assert ProviderSpec.fixed_url_provider?("openai") == false
    end

    test "returns false for unknown atoms and strings" do
      assert ProviderSpec.fixed_url_provider?(:unknown_provider) == false
      assert ProviderSpec.fixed_url_provider?("not_a_real_provider") == false
    end
  end

  describe "build/1" do
    test "sets base_url from credential endpoint for custom OpenAI-compatible providers" do
      credential =
        ai_credential_fixture(%{
          name: "Custom Endpoint Credential #{System.unique_integer([:positive, :monotonic])}",
          provider: "openai",
          endpoint: "https://my-llm.example.com/v1",
          api_key: "test-key"
        })

      configured_agent = %ConfiguredAgent{
        id: System.unique_integer([:positive]),
        name: "Custom Endpoint Agent",
        job: "test",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        credential: nil,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      }

      assert {:ok, spec} = ProviderSpec.build(configured_agent)
      assert spec.provider == :openai
      assert spec.id == "gpt-4.1-mini"
      assert spec.base_url == "https://my-llm.example.com/v1"
    end

    test "does not set base_url for fixed-URL providers like anthropic" do
      credential =
        ai_credential_fixture(%{
          name: "Anthropic Credential #{System.unique_integer([:positive, :monotonic])}",
          provider: "anthropic",
          endpoint: "https://irrelevant.anthropic.com",
          api_key: "anth-key"
        })

      configured_agent = %ConfiguredAgent{
        id: System.unique_integer([:positive]),
        name: "Anthropic Agent",
        job: "test",
        model: "claude-opus-4-5-20251001",
        credential_id: credential.id,
        credential: nil,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      }

      assert {:ok, spec} = ProviderSpec.build(configured_agent)
      assert spec.provider == :anthropic
      refute Map.has_key?(spec, :base_url)
    end

    test "falls back to :openai for unknown provider with custom endpoint" do
      credential =
        ai_credential_fixture(%{
          name: "Unknown Provider Credential #{System.unique_integer([:positive, :monotonic])}",
          provider: "unknown_provider_xyz",
          endpoint: "https://custom.endpoint.example.com/v1",
          api_key: nil
        })

      configured_agent = %ConfiguredAgent{
        id: System.unique_integer([:positive]),
        name: "Unknown Provider Agent",
        job: "test",
        model: "some-model",
        credential_id: credential.id,
        credential: nil,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      }

      assert {:ok, spec} = ProviderSpec.build(configured_agent)
      assert spec.provider == :openai
      assert spec.base_url == "https://custom.endpoint.example.com/v1"
    end

    test "returns provider_not_found error when provider unknown and no custom endpoint" do
      configured_agent = %ConfiguredAgent{
        id: System.unique_integer([:positive]),
        name: "No Endpoint Agent",
        job: "test",
        model: "some-model",
        credential: %{provider: "totally_unknown_xyz", endpoint: nil, api_key: nil},
        credential_id: nil,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      }

      assert {:error, :provider_not_found} = ProviderSpec.build(configured_agent)
    end
  end
end
