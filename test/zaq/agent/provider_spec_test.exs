defmodule Zaq.Agent.ProviderSpecTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.ProviderSpec

  # Minimal ConfiguredAgent map used across tests — only the fields ProviderSpec touches.
  defp agent_base do
    %ConfiguredAgent{
      id: System.unique_integer([:positive]),
      name: "Test Agent",
      job: "test",
      model: "gpt-4.1-mini",
      credential: nil,
      credential_id: nil,
      strategy: "react",
      enabled_tool_keys: [],
      conversation_enabled: false,
      active: true,
      advanced_options: %{}
    }
  end

  describe "reqllm_provider/1" do
    test "known native provider returns its catalog atom" do
      assert ProviderSpec.reqllm_provider("openai") == :openai
      assert ProviderSpec.reqllm_provider("anthropic") == :anthropic
    end

    test "ReqLLM-only OpenAI Codex provider returns its runtime atom" do
      assert ProviderSpec.reqllm_provider("openai_codex") == :openai_codex
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

    test "uses OpenAI Codex runtime provider for Codex credentials" do
      credential =
        ai_credential_fixture(%{
          name: "Codex Credential #{System.unique_integer([:positive, :monotonic])}",
          provider: "openai_codex",
          endpoint: "https://chatgpt.com/backend-api",
          api_key: nil,
          metadata: %{"auth_profile" => "openai_chatgpt_codex"}
        })

      configured_agent = %{
        agent_base()
        | model: "gpt-5.3-codex-spark",
          credential_id: credential.id
      }

      assert {:ok, spec} = ProviderSpec.build(configured_agent)
      assert spec.provider == :openai_codex
      assert spec.id == "gpt-5.3-codex-spark"
      assert spec.base_url == "https://chatgpt.com/backend-api"
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

    test "returns error when provider cannot be resolved (non-existent credential_id)" do
      # get_ai_provider_credential returns nil → provider_for_agent returns nil →
      # runtime_provider_for_agent returns {:error, :invalid_provider} → propagated via error ->
      configured_agent = %{agent_base() | credential: nil, credential_id: 999_999_999}
      assert {:error, _} = ProviderSpec.build(configured_agent)
    end

    test "uses pre-attached credential without DB lookup" do
      credential = %{
        provider: "openai",
        endpoint: "https://pre-attached.example.com/v1",
        api_key: "pre-key"
      }

      configured_agent = %{agent_base() | credential: credential, credential_id: nil}

      assert {:ok, spec} = ProviderSpec.build(configured_agent)
      assert spec.provider == :openai
      assert spec.base_url == "https://pre-attached.example.com/v1"
    end
  end

  describe "build/0" do
    test "returns a spec map with provider and id from seeded LLM config" do
      seed_llm_config(%{
        provider: "openai",
        endpoint: "http://test-llm.example.com/v1",
        api_key: "build-zero-key"
      })

      spec = ProviderSpec.build()
      assert is_map(spec)
      assert spec.provider == :openai
      assert is_binary(spec.id)
    end
  end

  describe "build/1 with config map" do
    test "openai with endpoint sets base_url" do
      spec =
        ProviderSpec.build(%{
          provider: "openai",
          model: "gpt-4",
          endpoint: "https://api.openai.example.com/v1"
        })

      assert spec.provider == :openai
      assert spec.id == "gpt-4"
      assert spec.base_url == "https://api.openai.example.com/v1"
    end

    test "anthropic with endpoint does not set base_url" do
      spec =
        ProviderSpec.build(%{
          provider: "anthropic",
          model: "claude-opus",
          endpoint: "https://ignored.com"
        })

      assert spec.provider == :anthropic
      refute Map.has_key?(spec, :base_url)
    end

    test "openai without endpoint key does not set base_url" do
      spec = ProviderSpec.build(%{provider: "openai", model: "gpt-4"})
      assert spec.provider == :openai
      refute Map.has_key?(spec, :base_url)
    end

    test "openai with empty endpoint does not set base_url" do
      spec = ProviderSpec.build(%{provider: "openai", model: "gpt-4", endpoint: ""})
      refute Map.has_key?(spec, :base_url)
    end
  end

  describe "put_base_url/2" do
    test "adds base_url for non-fixed provider with a binary endpoint" do
      spec =
        ProviderSpec.put_base_url(%{provider: :openai, id: "gpt-4"}, %{
          provider: "openai",
          endpoint: "https://custom.example.com/v1"
        })

      assert spec.base_url == "https://custom.example.com/v1"
    end

    test "skips base_url for fixed-URL providers regardless of endpoint" do
      spec =
        ProviderSpec.put_base_url(%{provider: :anthropic, id: "claude"}, %{
          provider: "anthropic",
          endpoint: "https://irrelevant.com"
        })

      refute Map.has_key?(spec, :base_url)
    end

    test "skips base_url when endpoint is missing" do
      spec = ProviderSpec.put_base_url(%{provider: :openai, id: "gpt-4"}, %{provider: "openai"})
      refute Map.has_key?(spec, :base_url)
    end

    test "skips base_url when endpoint is empty string" do
      spec =
        ProviderSpec.put_base_url(%{provider: :openai, id: "gpt-4"}, %{
          provider: "openai",
          endpoint: ""
        })

      refute Map.has_key?(spec, :base_url)
    end

    test "fallback clause skips base_url when second arg has no provider key" do
      spec = ProviderSpec.put_base_url(%{provider: :openai, id: "gpt-4"}, %{model: "something"})
      refute Map.has_key?(spec, :base_url)
    end
  end

  describe "put_base_url/3" do
    test "adds base_url for non-fixed provider with non-empty endpoint" do
      spec =
        ProviderSpec.put_base_url(%{provider: :openai}, :openai, %{
          endpoint: "https://custom.com/v1"
        })

      assert spec.base_url == "https://custom.com/v1"
    end

    test "skips base_url for fixed-URL provider" do
      spec =
        ProviderSpec.put_base_url(%{provider: :anthropic}, :anthropic, %{
          endpoint: "https://ignored.com"
        })

      refute Map.has_key?(spec, :base_url)
    end

    test "skips base_url when credential has empty endpoint" do
      spec = ProviderSpec.put_base_url(%{provider: :openai}, :openai, %{endpoint: ""})
      refute Map.has_key?(spec, :base_url)
    end

    test "skips base_url when credential has no endpoint field" do
      spec = ProviderSpec.put_base_url(%{provider: :openai}, :openai, %{api_key: "key"})
      refute Map.has_key?(spec, :base_url)
    end

    test "skips base_url when credential is nil-like" do
      spec = ProviderSpec.put_base_url(%{provider: :openai}, :openai, %{endpoint: nil})
      refute Map.has_key?(spec, :base_url)
    end
  end

  describe "generation_opts/1" do
    defp base_cfg(overrides \\ %{}) do
      Map.merge(
        %{
          temperature: 0.7,
          top_p: 0.9,
          api_key: nil,
          provider: "openai",
          supports_logprobs: false
        },
        overrides
      )
    end

    test "includes temperature and top_p" do
      opts = ProviderSpec.generation_opts(base_cfg())
      assert opts[:temperature] == 0.7
      assert opts[:top_p] == 0.9
    end

    test "includes api_key when present and non-empty" do
      opts = ProviderSpec.generation_opts(base_cfg(%{api_key: "my-key"}))
      assert opts[:api_key] == "my-key"
    end

    test "omits api_key when nil" do
      opts = ProviderSpec.generation_opts(base_cfg(%{api_key: nil}))
      refute Keyword.has_key?(opts, :api_key)
    end

    test "omits api_key when empty string" do
      opts = ProviderSpec.generation_opts(base_cfg(%{api_key: ""}))
      refute Keyword.has_key?(opts, :api_key)
    end

    test "does not add logprobs provider_options even when supports_logprobs and openai provider" do
      opts =
        ProviderSpec.generation_opts(base_cfg(%{supports_logprobs: true, provider: "openai"}))

      refute Keyword.has_key?(opts, :provider_options)
    end

    test "omits provider_options when supports_logprobs but non-openai provider" do
      opts =
        ProviderSpec.generation_opts(base_cfg(%{supports_logprobs: true, provider: "anthropic"}))

      refute Keyword.has_key?(opts, :provider_options)
    end

    test "omits provider_options when supports_logprobs is false" do
      opts =
        ProviderSpec.generation_opts(base_cfg(%{supports_logprobs: false, provider: "openai"}))

      refute Keyword.has_key?(opts, :provider_options)
    end
  end

  describe "default_advanced_options/1" do
    test "returns logprobs option when supports_logprobs and openai provider" do
      result =
        ProviderSpec.default_advanced_options(%{supports_logprobs: true, provider: "openai"})

      assert result == %{provider_options: [openai_logprobs: true]}
    end

    test "returns empty map when supports_logprobs but non-openai provider" do
      result =
        ProviderSpec.default_advanced_options(%{supports_logprobs: true, provider: "anthropic"})

      assert result == %{}
    end

    test "returns empty map when supports_logprobs is false" do
      result =
        ProviderSpec.default_advanced_options(%{supports_logprobs: false, provider: "openai"})

      assert result == %{}
    end

    test "returns empty map for config without supports_logprobs key" do
      result = ProviderSpec.default_advanced_options(%{provider: "openai"})
      assert result == %{}
    end
  end

  describe "llm_opts/1" do
    test "includes api_key and base_url from pre-attached credential" do
      credential = %{api_key: "live-key", endpoint: "https://live.example.com/v1"}
      agent = %{agent_base() | credential: credential}

      opts = ProviderSpec.llm_opts(agent)
      assert opts[:api_key] == "live-key"
      assert opts[:base_url] == "https://live.example.com/v1"
    end

    test "looks up credential by id when not pre-attached" do
      db_credential =
        ai_credential_fixture(%{
          api_key: "db-api-key",
          endpoint: "https://db.example.com/v1"
        })

      agent = %{agent_base() | credential: nil, credential_id: db_credential.id}

      opts = ProviderSpec.llm_opts(agent)
      assert opts[:api_key] == "db-api-key"
      assert opts[:base_url] == "https://db.example.com/v1"
    end

    test "returns empty list when no credential and no credential_id" do
      agent = %{agent_base() | credential: nil, credential_id: nil}
      opts = ProviderSpec.llm_opts(agent)
      assert opts == []
    end

    test "nil credential values are omitted from opts" do
      credential = %{api_key: nil, endpoint: nil}
      agent = %{agent_base() | credential: credential}

      opts = ProviderSpec.llm_opts(agent)
      refute Keyword.has_key?(opts, :api_key)
      refute Keyword.has_key?(opts, :base_url)
    end

    test "OpenAI Codex credential uses OAuth access token options instead of api_key" do
      credential = %{
        provider: "openai_codex",
        endpoint: "https://chatgpt.com/backend-api",
        access_token: "oauth-token",
        api_key: "ignored-key",
        metadata: %{
          "auth_profile" => "openai_chatgpt_codex",
          "authorize_params" => %{"originator" => "zaqos"},
          "chatgpt_account_id" => "acct_123"
        }
      }

      agent = %{agent_base() | credential: credential}

      opts = ProviderSpec.llm_opts(agent)
      refute Keyword.has_key?(opts, :api_key)
      assert opts[:access_token] == "oauth-token"
      assert opts[:auth_mode] == :oauth
      assert opts[:base_url] == "https://chatgpt.com/backend-api"
      assert opts[:provider_options][:auth_mode] == :oauth
      assert opts[:provider_options][:codex_originator] == "zaqos"
      assert opts[:provider_options][:chatgpt_account_id] == "acct_123"
    end

    test "atom keys in advanced_options are included" do
      agent = %{agent_base() | advanced_options: %{temperature: 0.5, top_p: 0.8}}
      opts = ProviderSpec.llm_opts(agent)
      assert opts[:temperature] == 0.5
      assert opts[:top_p] == 0.8
    end

    test "string keys in advanced_options are converted to atoms" do
      agent = %{agent_base() | advanced_options: %{"temperature" => 0.3}}
      opts = ProviderSpec.llm_opts(agent)
      assert opts[:temperature] == 0.3
    end

    test "unknown string keys in advanced_options are silently dropped" do
      # Use a runtime-generated key so it is never registered as an existing atom.
      unique_key = "zaq_never_valid_llm_opt_#{System.unique_integer([:positive])}"

      agent = %{
        agent_base()
        | advanced_options: %{unique_key => "val"},
          credential: nil,
          credential_id: nil
      }

      opts = ProviderSpec.llm_opts(agent)
      assert opts == []
    end

    test "nil advanced_options returns empty list (plus any credential keys)" do
      agent = %{agent_base() | advanced_options: nil, credential: nil, credential_id: nil}
      opts = ProviderSpec.llm_opts(agent)
      assert opts == []
    end
  end
end
