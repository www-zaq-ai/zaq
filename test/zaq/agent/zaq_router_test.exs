defmodule Zaq.Agent.ZAQRouterTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Zaq.Agent.ProviderModels
  alias Zaq.Agent.ZAQRouter
  alias Zaq.System.OperationModelConfig
  alias Zaq.System.OperationModelConfig, as: RAGModelConfig
  alias Zaq.TestSupport.ModelCatalogFixture

  @catalog_metadata %{
    "openai/gpt-oss-120b" => {131_072, true},
    "qwen/qwen3-235b-a22b-2507" => {262_144, true},
    "google/gemma-4-31b-it" => {262_144, true},
    "deepseek/deepseek-v4-pro" => {1_048_576, true},
    "moonshotai/kimi-k3" => {1_048_576, true},
    "deepseek/deepseek-v4.1-flash" => {1_048_576, true},
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning" => {256_000, true},
    "google/gemma-3-27b-it" => {131_072, true},
    "google/gemini-2.5-flash-lite" => {1_048_576, true},
    "qwen/qwen3-vl-235b-a22b-instruct" => {262_144, true},
    "nvidia/llama-nemotron-embed-vl-1b-v2" => {10_240, false},
    "openai/text-embedding-3-small" => {8192, false},
    "google/gemini-embedding-001" => {2048, false},
    "openai/text-embedding-3-large" => {8192, false},
    "openai/gpt-oss-20b" => {131_072, true},
    "baai/bge-m3" => {8192, false},
    "typesafe/jev-1.14" => {65_536, false},
    "Qwen/Qwen3-Reranker-0.6B" => {32_768, false},
    "moonshotai/kimi-k3.1-pro" => {1_048_576, true},
    "z-ai/glm-5.3-flash" => {1_048_576, true}
  }

  @generation_inputs %{
    "openai/gpt-oss-120b" => [:text],
    "openai/gpt-oss-20b" => [:text],
    "qwen/qwen3-235b-a22b-2507" => [:text],
    "deepseek/deepseek-v4-pro" => [:text],
    "deepseek/deepseek-v4.1-flash" => [:text, :image],
    "google/gemma-3-27b-it" => [:text, :image],
    "qwen/qwen3-vl-235b-a22b-instruct" => [:text, :image],
    "google/gemma-4-31b-it" => [:text, :image, :video],
    "moonshotai/kimi-k3" => [:text, :image, :video],
    "moonshotai/kimi-k3.1-pro" => [:text, :image, :video],
    "z-ai/glm-5.3-flash" => [:text, :image, :video],
    "google/gemini-2.5-flash-lite" => [:text, :image, :audio, :video, :file],
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning" => [:text, :image, :audio, :video]
  }

  setup tags do
    snapshot = LLMDB.Store.snapshot()
    opts = LLMDB.Store.last_opts()

    on_exit(fn ->
      if snapshot, do: LLMDB.Store.put!(snapshot, opts), else: LLMDB.Store.clear!()
    end)

    catalog_opts =
      if tags[:reload_fixture], do: ModelCatalogFixture.minimal_source_opts!(), else: []

    {:ok, catalog_opts: catalog_opts}
  end

  describe "llmdb_opts/0" do
    test "advertises exact modalities and generation capabilities" do
      assert {:ok, _} = LLMDB.load(ZAQRouter.llmdb_opts())

      for {id, input} <- @generation_inputs do
        assert {:ok, model} = LLMDB.model(:zaq_router, id)
        assert model.modalities == %{input: input, output: [:text]}
        assert model.capabilities.chat
        assert model.capabilities.tools.enabled
        assert model.capabilities.streaming == %{text: true, tool_calls: true}
        refute model.capabilities.embeddings
        refute model.capabilities.rerank

        reasoning? =
          id not in [
            "qwen/qwen3-235b-a22b-2507",
            "qwen/qwen3-vl-235b-a22b-instruct",
            "google/gemma-3-27b-it"
          ]

        assert model.capabilities.reasoning.enabled == reasoning?
        json? = id != "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
        assert model.capabilities.json.native == json?
        assert model.capabilities.json.schema == json?
        assert is_nil(model.capabilities.json.strict)
      end
    end

    test "specialized models cannot leak into generation selectors" do
      assert {:ok, _} = LLMDB.load(ZAQRouter.llmdb_opts())

      embeddings = [
        {"nvidia/llama-nemotron-embed-vl-1b-v2", [:text, :image], 2048, 2048},
        {"openai/text-embedding-3-large", [:text], 1, 3072},
        {"openai/text-embedding-3-small", [:text], 1, 1536},
        {"google/gemini-embedding-001", [:text], 128, 3072},
        {"baai/bge-m3", [:text], 1024, 1024}
      ]

      for {id, input, min, dimensions} <- embeddings do
        assert {:ok, model} = LLMDB.model(:zaq_router, id)
        assert model.modalities == %{input: input, output: [:embeddings]}

        assert model.capabilities.embeddings == %{
                 min_dimensions: min,
                 max_dimensions: dimensions,
                 default_dimensions: dimensions
               }
      end

      for id <- Map.keys(@catalog_metadata) -- Map.keys(@generation_inputs) do
        assert {:ok, model} = LLMDB.model(:zaq_router, id)
        refute model.capabilities.chat
        refute model.capabilities.tools.enabled
        assert model.capabilities.streaming == %{text: false, tool_calls: false}
        refute OperationModelConfig.supports?(model)
      end

      assert {:ok, reranker} = LLMDB.model(:zaq_router, "Qwen/Qwen3-Reranker-0.6B")
      assert reranker.modalities == %{input: [:text], output: [:rerank]}
      assert RAGModelConfig.supports?(reranker, :reranking)
      assert {:ok, decision} = LLMDB.model(:zaq_router, "typesafe/jev-1.14")
      assert decision.modalities == %{input: [:text, :image], output: [:decisions]}
      assert decision.capabilities.evaluate
      assert RAGModelConfig.supports?(decision, :decision)
    end

    test "all provisioning defaults are advertised" do
      assert ZAQRouter.default_chat_model() == "openai/gpt-oss-120b"
      assert ZAQRouter.default_embedding_model() == {"baai/bge-m3", 1024}
      assert ZAQRouter.default_image_model() == "deepseek/deepseek-v4.1-flash"
      assert ZAQRouter.default_translation_model() == "openai/gpt-oss-20b"
      assert ZAQRouter.default_reranking_model() == "Qwen/Qwen3-Reranker-0.6B"
      assert ZAQRouter.default_decision_model() == "typesafe/jev-1.14"
    end

    test "Small model default is eligible for text generation" do
      assert ZAQRouter.default_small_model() == "openai/gpt-oss-20b"
      assert {:ok, _} = LLMDB.load(ZAQRouter.llmdb_opts())
      assert {:ok, model} = LLMDB.model(:zaq_router, ZAQRouter.default_small_model())
      assert OperationModelConfig.supports?(model)
    end

    test "advertises context limits and tool support for every default model" do
      assert {:ok, _snapshot} = LLMDB.load(ZAQRouter.llmdb_opts())

      models = LLMDB.models(:zaq_router)
      assert Enum.sort(Enum.map(models, & &1.id)) == Enum.sort(Map.keys(@catalog_metadata))

      for model <- models do
        {context, tools?} = Map.fetch!(@catalog_metadata, model.id)
        assert model.limits.context == context
        assert model.capabilities.tools.enabled == tools?
      end
    end

    @tag :reload_fixture
    test "exposes new model metadata through the agent model lookup", %{
      catalog_opts: catalog_opts
    } do
      assert {:ok, _snapshot} = LLMDB.load(ZAQRouter.llmdb_opts() ++ catalog_opts)

      for id <- ["moonshotai/kimi-k3", "deepseek/deepseek-v4.1-flash"] do
        model = ProviderModels.model("zaq_router", id)
        assert model.id == id
        assert model.limits.context == 1_048_576
        assert model.capabilities.chat
        assert model.capabilities.tools.enabled
        assert model.capabilities.reasoning.enabled
      end
    end
  end

  describe "reload/1" do
    @describetag :reload_fixture

    property "reload keeps exactly the requested IDs and their known metadata", %{
      catalog_opts: catalog_opts
    } do
      check all(
              ids <- list_of(member_of(Map.keys(@catalog_metadata) ++ ["unknown-model"])),
              max_runs: 10
            ) do
        assert {:ok, _snapshot} = ZAQRouter.reload(ids, catalog_opts)

        assert {:ok, %LLMDB.Model{id: "gpt-4.1-mini", provider: :openai}} =
                 LLMDB.model(:openai, "gpt-4.1-mini")

        models = LLMDB.models(:zaq_router)
        assert Enum.sort(Enum.map(models, & &1.id)) == Enum.sort(Enum.uniq(ids))

        for model <- models, model.id != "unknown-model" do
          {context, tools?} = Map.fetch!(@catalog_metadata, model.id)
          assert model.limits.context == context
          assert model.capabilities.tools.enabled == tools?
        end
      end
    end

    test "preserves the full default metadata for known models in a mixed list", %{
      catalog_opts: catalog_opts
    } do
      assert {:ok, _snapshot} = LLMDB.load(ZAQRouter.llmdb_opts() ++ catalog_opts)
      defaults = Map.new(LLMDB.models(:zaq_router), &{&1.id, &1})

      assert {:ok, _snapshot} =
               ZAQRouter.reload(Map.keys(defaults) ++ ["unknown-model"], catalog_opts)

      for {id, expected} <- defaults do
        assert {:ok, actual} = LLMDB.model(:zaq_router, id)
        assert actual == expected
      end

      assert {:ok, unknown} = LLMDB.model(:zaq_router, "unknown-model")
      assert unknown.capabilities.chat
      assert unknown.capabilities.tools == %{enabled: true}
      assert is_nil(unknown.limits) or is_nil(unknown.limits[:context])
    end

    test "non-empty list returns {:ok, _} and registers models in LLMDB", %{
      catalog_opts: catalog_opts
    } do
      assert {:ok, _snapshot} = ZAQRouter.reload(["model-a", "model-b"], catalog_opts)

      model_ids = LLMDB.models(:zaq_router) |> Enum.map(& &1.id)
      assert Enum.sort(model_ids) == Enum.sort(["model-a", "model-b"])

      for model <- LLMDB.models(:zaq_router) do
        assert model.capabilities.chat == true
        assert model.capabilities.tools == %{enabled: true}
      end
    end

    test "empty list returns {:ok, _} and results in no models for :zaq_router", %{
      catalog_opts: catalog_opts
    } do
      assert {:ok, _snapshot} = ZAQRouter.reload([], catalog_opts)

      assert LLMDB.models(:zaq_router) == []
    end

    test "second reload replaces previous catalog — does not append", %{
      catalog_opts: catalog_opts
    } do
      assert {:ok, _} = ZAQRouter.reload(["old-model"], catalog_opts)
      assert {:ok, _} = ZAQRouter.reload(["new-model"], catalog_opts)

      model_ids = LLMDB.models(:zaq_router) |> Enum.map(& &1.id)
      assert model_ids == ["new-model"]
      refute "old-model" in model_ids
    end
  end
end
