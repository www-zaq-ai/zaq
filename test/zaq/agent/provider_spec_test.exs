defmodule Zaq.Agent.ProviderSpecTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.ProviderSpec
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.ResolvedCredential
  alias Zaq.System.OperationModelConfig, as: RAGModelConfig

  describe "operation_runtime/2 reranking" do
    test "catalog execution contracts preserve provider identity without a native adapter" do
      credential =
        ai_credential_fixture(%{
          provider: "albert",
          api_key: "test-albert-key"
        })

      assert {:error, _} = ReqLLM.provider(:albert)

      for id <- ["bge-reranker-v2-m3", "openweight-rerank"] do
        config = %RAGModelConfig{credential_id: credential.id, model: id}

        assert {:ok, model, opts} = ProviderSpec.operation_runtime(config, :reranking)
        assert model.provider == :albert
        assert model.id == "bge-reranker-v2-m3"
        assert model.provider_model_id == "openweight-rerank"
        assert model.execution.rerank.supported
        assert opts[:api_key] == "test-albert-key"
        refute Keyword.has_key?(opts, :temperature)
        refute Keyword.has_key?(opts, :top_p)
      end
    end

    test "catalog reranking preserves the explicitly configured endpoint" do
      endpoint = "https://reranker.example/v1"

      credential =
        ai_credential_fixture(%{provider: "albert", endpoint: endpoint, api_key: "test-key"})

      config = %RAGModelConfig{credential_id: credential.id, model: "openweight-rerank"}

      assert {:ok, model, opts} = ProviderSpec.operation_runtime(config, :reranking)
      assert model.provider == :albert
      assert model.base_url == endpoint
      assert opts[:base_url] == endpoint
    end

    test "a catalog model without rerank execution does not fall back to another provider" do
      credential = ai_credential_fixture(%{provider: "albert", api_key: "test-key"})
      config = %RAGModelConfig{credential_id: credential.id, model: "bge-m3"}

      assert {:error, _} = ProviderSpec.operation_runtime(config, :reranking)
    end

    test "generation rejects a reranking-only model rather than rejecting its provider" do
      credential = ai_credential_fixture(%{provider: "albert", api_key: "test-key"})
      config = %RAGModelConfig{credential_id: credential.id, model: "openweight-rerank"}

      assert {:error, :model_not_supported} = ProviderSpec.operation_runtime(config)
    end

    test "registered ZAQ Router reranking keeps its configured model and authentication" do
      credential = ai_credential_fixture(%{provider: "zaq_router", api_key: "test-router-key"})
      config = %RAGModelConfig{credential_id: credential.id, model: "Qwen/Qwen3-Reranker-0.6B"}

      assert {:ok, model, opts} = ProviderSpec.operation_runtime(config, :reranking)
      assert model.provider == :zaq_router
      assert model.id == config.model
      assert opts[:api_key] == "test-router-key"
    end

    test "resolves reranking model authentication without text-generation options" do
      credential = ai_credential_fixture(%{provider: "cohere", api_key: "test-rerank-key"})
      config = %RAGModelConfig{credential_id: credential.id, model: "rerank-v3.5"}

      assert {:ok, model, opts} = ProviderSpec.operation_runtime(config, :reranking)
      assert model.provider == :cohere
      assert model.id == "rerank-v3.5"
      assert opts[:api_key] == "test-rerank-key"
      refute Keyword.has_key?(opts, :temperature)
      refute Keyword.has_key?(opts, :top_p)
    end

    test "rejects a configured model without reranking capability" do
      credential = ai_credential_fixture(%{provider: "openai", api_key: "test-key"})
      config = %RAGModelConfig{credential_id: credential.id, model: "gpt-4.1-mini"}
      assert {:error, _} = ProviderSpec.operation_runtime(config, :reranking)
    end

    test "missing credential or incomplete selection returns an error" do
      for config <- [
            %RAGModelConfig{},
            %RAGModelConfig{model: "rerank-v3.5"},
            %RAGModelConfig{credential_id: -1, model: "rerank-v3.5"}
          ] do
        assert {:error, _} = ProviderSpec.operation_runtime(config, :reranking)
      end
    end
  end

  describe "mixed-operation catalog providers" do
    test "agent preflight and dedicated generation use the same chat compatibility path" do
      endpoint = "https://albert.api.etalab.gouv.fr/v1"

      credential =
        ai_credential_fixture(%{provider: "albert", endpoint: endpoint, api_key: "test-key"})

      {:ok, provider} = LLMDB.provider(:albert)
      refute provider.catalog_only

      for id <- ["gpt-oss-120b", "openweight-large"] do
        agent = %ConfiguredAgent{credential: credential, model: id}
        assert {:ok, :openai} = Zaq.Agent.runtime_provider_for_agent(agent)

        assert {:ok, %{provider: :openai, id: ^id, base_url: ^endpoint}} =
                 ProviderSpec.build(agent)

        config = %RAGModelConfig{credential_id: credential.id, model: id}
        assert {:ok, model, opts} = ProviderSpec.operation_runtime(config)
        assert model.provider == :openai
        assert model.id == id
        assert model.base_url == endpoint
        assert opts[:api_key] == "test-key"
        assert opts[:base_url] == endpoint
      end

      config = %RAGModelConfig{credential_id: credential.id, model: "openweight-rerank"}
      assert {:ok, %{provider: :albert}, _} = ProviderSpec.operation_runtime(config, :reranking)
    end

    test "compatibility fallback requires a selected catalog chat model and explicit endpoint" do
      for {model, endpoint, reason} <- [
            {"not-in-the-catalog", "https://provider.example/v1", :provider_not_supported},
            {"gpt-oss-120b", nil, :provider_not_supported},
            {"bge-m3", "https://provider.example/v1", :model_not_supported},
            {"mistral-ocr-2512", "https://provider.example/v1", :model_not_supported},
            {"whisper-large-v3", "https://provider.example/v1", :model_not_supported}
          ] do
        agent = %ConfiguredAgent{
          model: model,
          credential: %{provider: "albert", endpoint: endpoint}
        }

        assert {:error, ^reason} = ProviderSpec.build(agent)
        assert {:error, ^reason} = Zaq.Agent.runtime_provider_for_agent(agent)
      end
    end

    test "Albert generation reaches the configured endpoint through real ReqLLM" do
      credential =
        ai_credential_fixture(%{
          provider: "albert",
          endpoint: "https://albert.api.etalab.gouv.fr/v1",
          api_key: "test-generation-key"
        })

      config = %RAGModelConfig{credential_id: credential.id, model: "openweight-large"}
      assert {:ok, model, opts} = ProviderSpec.operation_runtime(config)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "albert.api.etalab.gouv.fr"
        assert conn.request_path == "/v1/chat/completions"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-generation-key"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["model"] == "openweight-large"

        Req.Test.json(conn, %{
          id: "albert-chat",
          object: "chat.completion",
          model: "openweight-large",
          choices: [
            %{index: 0, message: %{role: "assistant", content: "Hello"}, finish_reason: "stop"}
          ],
          usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
        })
      end)

      opts = Keyword.put(opts, :req_http_options, plug: {Req.Test, __MODULE__}, retry: false)
      assert {:ok, response} = ReqLLM.generate_text(model, "Hello", opts)
      assert ReqLLM.Response.text(response) == "Hello"
    end

    property "catalog non-chat models cannot become generation models through endpoint fallback" do
      candidates =
        for provider <- LLMDB.providers(),
            model <- LLMDB.models(provider.id),
            get_in(model.capabilities, [:chat]) == false,
            do: {provider.id, model.id}

      check all({provider, id} <- member_of(candidates), max_runs: 50) do
        agent = %ConfiguredAgent{
          model: id,
          credential: %{provider: to_string(provider), endpoint: "https://provider.example/v1"}
        }

        assert {:error, :model_not_supported} = ProviderSpec.build(agent)
        assert {:error, :model_not_supported} = Zaq.Agent.runtime_provider_for_agent(agent)
      end
    end
  end

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

  describe "known_provider?/1" do
    test "recognizes catalog identities independently of generation adapter fallback" do
      assert ProviderSpec.known_provider?(:openai)
      assert ProviderSpec.known_provider?("OpenAI")
      assert ProviderSpec.known_provider?(:albert)
      assert ProviderSpec.known_provider?("AlBeRt")

      agent = %ConfiguredAgent{
        model: "openweight-large",
        credential: %{provider: "AlBeRt", endpoint: "https://albert.api.etalab.gouv.fr/v1"}
      }

      assert {:ok, %{provider: :openai}} = ProviderSpec.build(agent)
    end

    test "recognizes registered providers that are absent from the catalog" do
      assert {:error, _} = LLMDB.provider(:openai_codex)

      for provider <- [:openai_codex, "openai_codex", "OPENAI_CODEX", :zaq_router] do
        assert ProviderSpec.known_provider?(provider)
      end
    end

    test "an unknown custom endpoint can execute without becoming a known provider" do
      provider = "unregistered-provider-spec-#{System.unique_integer([:positive, :monotonic])}"

      agent = %ConfiguredAgent{
        model: "custom-model",
        credential: %{provider: provider, endpoint: "https://custom.example/v1"}
      }

      refute ProviderSpec.known_provider?(provider)
      assert {:ok, %{provider: :openai}} = ProviderSpec.build(agent)
      assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
    end

    test "existing atoms and invalid inputs are not sufficient for recognition" do
      for provider <- [:unregistered_provider_spec_atom, nil, "", 42, %{}, ["openai"]] do
        refute ProviderSpec.known_provider?(provider)
      end
    end

    property "catalog and registered identities are recognized across input forms" do
      providers = Enum.map(LLMDB.providers(), & &1.id) ++ ReqLLM.Providers.list()

      check all(provider <- member_of(providers)) do
        assert ProviderSpec.known_provider?(provider)
        assert ProviderSpec.known_provider?(Atom.to_string(provider))
        assert ProviderSpec.known_provider?(provider |> Atom.to_string() |> String.upcase())
      end
    end

    property "unknown provider recognition never creates atoms" do
      check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 40)) do
        provider = "unregistered-provider-spec-#{suffix}"
        refute ProviderSpec.known_provider?(provider)
        assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
      end
    end
  end

  describe "reqllm_provider/1" do
    test "known native provider returns its catalog atom" do
      assert ProviderSpec.reqllm_provider("openai") == :openai
      assert ProviderSpec.reqllm_provider("anthropic") == :anthropic
    end

    test "ZAQ router resolves to its own registered ReqLLM provider" do
      assert ProviderSpec.reqllm_provider(:zaq_router) == :zaq_router
      assert ProviderSpec.reqllm_provider("zaq_router") == :zaq_router
    end

    test "ZAQ router is registered in the ReqLLM provider registry" do
      assert {:ok, Zaq.Agent.Providers.ZAQRouter} = ReqLLM.provider(:zaq_router)
    end

    test "catalog-only providers still fall back to OpenAI-compatible routing" do
      assert ProviderSpec.reqllm_provider("novita_ai") == :openai
    end

    test "ReqLLM-only OpenAI Codex provider returns its runtime atom" do
      assert ProviderSpec.reqllm_provider("openai_codex") == :openai_codex
    end

    test "OpenAI Codex atom returns its runtime atom" do
      assert ProviderSpec.reqllm_provider(:openai_codex) == :openai_codex
    end

    test "known native provider accepts atom input" do
      assert ProviderSpec.reqllm_provider(:openai) == :openai
    end

    test "unknown provider falls back to :openai" do
      assert ProviderSpec.reqllm_provider("totally_nonexistent_xyz") == :openai
    end

    # The :openai fallback lives in reqllm_provider_from_llmdb/1, which is only
    # reached when ReqLLM has no module for the provider. A catalog_only provider
    # that *does* have one (azure, google_vertex, amazon_bedrock, ...) returns its
    # own atom from the first branch. Selecting by catalog_only alone picks an
    # arbitrary provider — LLMDB.providers/0 ordering is not guaranteed — so pin
    # the search to the combination the fallback actually covers.
    test "catalog_only provider with no ReqLLM module falls back to :openai" do
      catalog_only =
        LLMDB.providers()
        |> Enum.filter(& &1.catalog_only)
        |> Enum.find(&match?({:error, _}, ReqLLM.provider(&1.id)))

      assert catalog_only,
             "expected at least one catalog_only provider without a ReqLLM module"

      assert ProviderSpec.reqllm_provider(to_string(catalog_only.id)) == :openai
    end

    test "catalog_only provider with a ReqLLM module keeps its own atom" do
      assert ProviderSpec.reqllm_provider("azure") == :azure
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
          metadata: %{
            "auth_kind" => "oauth2",
            "auth_profile" => "openai_chatgpt_codex",
            "client_id" => "client-id"
          }
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

  describe "credential_opts/1" do
    test "OpenAI Codex credential accepts string access token key and missing metadata" do
      credential = %{
        "access_token" => "string-token",
        provider: "openai_codex"
      }

      opts = ProviderSpec.credential_opts(credential)

      assert opts[:access_token] == "string-token"
      assert opts[:auth_mode] == :oauth
      assert opts[:base_url] == "https://chatgpt.com/backend-api"
      assert opts[:provider_options][:auth_mode] == :oauth
      refute Keyword.has_key?(opts[:provider_options], :codex_originator)
      refute Keyword.has_key?(opts[:provider_options], :chatgpt_account_id)
      refute Keyword.has_key?(opts, :api_key)
    end

    test "OpenAI Codex credential without access token omits token but keeps OAuth defaults" do
      credential = %{provider: "openai_codex"}

      opts = ProviderSpec.credential_opts(credential)

      refute Keyword.has_key?(opts, :access_token)
      assert opts[:auth_mode] == :oauth
      assert opts[:base_url] == "https://chatgpt.com/backend-api"
      assert opts[:provider_options][:auth_mode] == :oauth
    end

    test "generic credential accepts string api_key key" do
      credential = %{
        "api_key" => "string-api-key",
        provider: "openai",
        endpoint: "https://generic.example.com/v1"
      }

      opts = ProviderSpec.credential_opts(credential)

      assert opts[:api_key] == "string-api-key"
      assert opts[:base_url] == "https://generic.example.com/v1"
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

    test "uses the canonical associated Connect grant instead of the legacy AI secret" do
      db_credential =
        ai_credential_fixture(%{
          api_key: "legacy-ai-key",
          endpoint: "https://canonical.example.com/v1"
        })

      assert {:ok, _grant} =
               Connect.replace_credential_grant(
                 db_credential.connect_credential_id,
                 :org,
                 %{api_key: "canonical-connect-key"}
               )

      agent = %{agent_base() | credential: nil, credential_id: db_credential.id}

      opts = ProviderSpec.llm_opts(agent)
      assert opts[:api_key] == "canonical-connect-key"
      refute opts[:api_key] == db_credential.api_key
    end

    test "returns agent sampling when no credential and no credential_id" do
      agent = %{agent_base() | credential: nil, credential_id: nil}
      opts = ProviderSpec.llm_opts(agent)
      assert opts == [temperature: 0.0, top_p: 0.9]
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

    test "dedicated sampling overrides overlapping atom keys in advanced_options" do
      agent = %{agent_base() | advanced_options: %{temperature: 0.5, top_p: 0.8}}
      opts = ProviderSpec.llm_opts(agent)
      assert opts[:temperature] == 0.0
      assert opts[:top_p] == 0.9
    end

    test "dedicated sampling overrides overlapping string keys in advanced_options" do
      agent = %{agent_base() | advanced_options: %{"temperature" => 0.3}}
      opts = ProviderSpec.llm_opts(agent)
      assert opts[:temperature] == 0.0
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
      assert opts == [temperature: 0.0, top_p: 0.9]
    end

    test "nil advanced_options retains explicit agent sampling" do
      agent = %{agent_base() | advanced_options: nil, credential: nil, credential_id: nil}
      opts = ProviderSpec.llm_opts(agent)
      assert opts == [temperature: 0.0, top_p: 0.9]
    end
  end

  describe "llm_opts/2" do
    test "translates one resolved Person authentication without consulting legacy secrets" do
      credential = %{
        provider: "openai",
        endpoint: "https://person.example.com/v1",
        api_key: "legacy-must-not-win"
      }

      agent = %{agent_base() | credential: credential}

      resolved = %ResolvedCredential{
        credential_id: 10,
        grant_id: 20,
        owner_type: "person",
        owner_id: 30,
        auth_kind: "api_key",
        request_format: "bearer",
        authentication: %{api_key: "person-key"}
      }

      assert {:ok, opts} = ProviderSpec.llm_opts(agent, resolved)
      assert opts[:api_key] == "person-key"
      assert opts[:base_url] == "https://person.example.com/v1"
      refute opts[:api_key] == credential.api_key
    end

    test "pairs Codex access token with the selected grant runtime identity" do
      credential = %{
        provider: "openai_codex",
        endpoint: "https://chatgpt.com/backend-api",
        metadata: %{
          "auth_profile" => "openai_chatgpt_codex",
          "chatgpt_account_id" => "acct_configuration"
        }
      }

      agent = %{agent_base() | credential: credential}

      resolved = %ResolvedCredential{
        credential_id: 10,
        grant_id: 20,
        owner_type: "person",
        owner_id: 30,
        auth_kind: "oauth2",
        request_format: "bearer",
        authentication: %{access_token: "person-token"},
        metadata: %{"chatgpt_account_id" => "acct_person"}
      }

      assert {:ok, opts} = ProviderSpec.llm_opts(agent, resolved)
      assert opts[:access_token] == "person-token"
      assert opts[:provider_options][:chatgpt_account_id] == "acct_person"
      refute opts[:provider_options][:chatgpt_account_id] == "acct_configuration"
    end

    test "resolved Codex authentication overrides conflicting advanced options" do
      credential = %{
        provider: "openai_codex",
        endpoint: "https://ignored.example",
        metadata: %{"auth_profile" => "openai_chatgpt_codex"}
      }

      agent = %{
        agent_base()
        | credential: credential,
          advanced_options: %{
            api_key: "wrong-key",
            access_token: "wrong-token",
            auth_mode: :api_key,
            base_url: "https://wrong.example",
            provider_options: [auth_mode: :api_key, chatgpt_account_id: "wrong-account"]
          }
      }

      resolved = %ResolvedCredential{
        credential_id: 10,
        grant_id: 20,
        owner_type: "person",
        owner_id: 30,
        auth_kind: "oauth2",
        request_format: "bearer",
        authentication: %{access_token: "person-token"},
        metadata: %{"chatgpt_account_id" => "acct_person"}
      }

      assert {:ok, opts} = ProviderSpec.llm_opts(agent, resolved)
      refute Keyword.has_key?(opts, :api_key)
      assert opts[:access_token] == "person-token"
      assert opts[:auth_mode] == :oauth
      assert opts[:base_url] == "https://chatgpt.com/backend-api"
      assert opts[:provider_options][:auth_mode] == :oauth
      assert opts[:provider_options][:chatgpt_account_id] == "acct_person"
    end

    test "rejects authentication kinds unsupported by the AI runtime" do
      resolved = %ResolvedCredential{
        credential_id: 10,
        grant_id: 20,
        owner_type: "org",
        owner_id: nil,
        auth_kind: "jwt_bearer",
        request_format: "bearer",
        authentication: %{
          private_key: "private",
          issuer: "issuer",
          key_id: "key",
          subject: nil,
          scopes: [],
          auth_profile_id: "service_account"
        }
      }

      assert {:error, {:unsupported_ai_authentication, "jwt_bearer"}} =
               ProviderSpec.llm_opts(agent_base(), resolved)
    end
  end
end
