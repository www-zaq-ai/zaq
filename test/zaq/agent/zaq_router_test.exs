defmodule Zaq.Agent.ZAQRouterTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Zaq.Agent.ProviderModels
  alias Zaq.Agent.ZAQRouter

  @catalog_metadata %{
    "openai/gpt-oss-120b" => {131_072, true},
    "qwen/qwen3-235b-a22b-2507" => {262_144, true},
    "mistralai/mistral-small-2603" => {262_144, true},
    "deepseek/deepseek-v4-pro" => {1_048_576, true},
    "moonshotai/kimi-k3" => {1_048_576, true},
    "deepseek/deepseek-v4.1-flash" => {1_048_576, true},
    "nvidia/nemotron-nano-12b-v2-vl" => {131_072, true},
    "google/gemma-3-27b-it" => {131_072, true},
    "google/gemini-2.5-flash-lite" => {1_048_576, true},
    "qwen/qwen3-vl-235b-a22b-instruct" => {262_144, true},
    "nvidia/llama-nemotron-embed-vl-1b-v2" => {10_240, false},
    "openai/text-embedding-3-small" => {8192, false},
    "google/gemini-embedding-001" => {2048, false},
    "openai/text-embedding-3-large" => {8192, false}
  }

  setup do
    on_exit(fn -> LLMDB.load() end)
    :ok
  end

  describe "llmdb_opts/0" do
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

    test "exposes new model metadata through the agent model lookup" do
      assert {:ok, _snapshot} = LLMDB.load(ZAQRouter.llmdb_opts())

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
    property "reload keeps exactly the requested IDs and their known metadata" do
      check all(
              ids <- list_of(member_of(Map.keys(@catalog_metadata) ++ ["unknown-model"])),
              max_runs: 10
            ) do
        assert {:ok, _snapshot} = ZAQRouter.reload(ids)

        models = LLMDB.models(:zaq_router)
        assert Enum.sort(Enum.map(models, & &1.id)) == Enum.sort(Enum.uniq(ids))

        for model <- models, model.id != "unknown-model" do
          {context, tools?} = Map.fetch!(@catalog_metadata, model.id)
          assert model.limits.context == context
          assert model.capabilities.tools.enabled == tools?
        end
      end
    end

    test "preserves the full default metadata for known models in a mixed list" do
      assert {:ok, _snapshot} = LLMDB.load(ZAQRouter.llmdb_opts())
      defaults = Map.new(LLMDB.models(:zaq_router), &{&1.id, &1})

      assert {:ok, _snapshot} = ZAQRouter.reload(Map.keys(defaults) ++ ["unknown-model"])

      for {id, expected} <- defaults do
        assert {:ok, actual} = LLMDB.model(:zaq_router, id)
        assert actual == expected
      end

      assert {:ok, unknown} = LLMDB.model(:zaq_router, "unknown-model")
      assert unknown.capabilities.chat
      assert unknown.capabilities.tools == %{enabled: true}
      assert is_nil(unknown.limits) or is_nil(unknown.limits[:context])
    end

    test "non-empty list returns {:ok, _} and registers models in LLMDB" do
      assert {:ok, _snapshot} = ZAQRouter.reload(["model-a", "model-b"])

      model_ids = LLMDB.models(:zaq_router) |> Enum.map(& &1.id)
      assert Enum.sort(model_ids) == Enum.sort(["model-a", "model-b"])

      for model <- LLMDB.models(:zaq_router) do
        assert model.capabilities.chat == true
        assert model.capabilities.tools == %{enabled: true}
      end
    end

    test "empty list returns {:ok, _} and results in no models for :zaq_router" do
      assert {:ok, _snapshot} = ZAQRouter.reload([])

      assert LLMDB.models(:zaq_router) == []
    end

    test "second reload replaces previous catalog — does not append" do
      assert {:ok, _} = ZAQRouter.reload(["old-model"])
      assert {:ok, _} = ZAQRouter.reload(["new-model"])

      model_ids = LLMDB.models(:zaq_router) |> Enum.map(& &1.id)
      assert model_ids == ["new-model"]
      refute "old-model" in model_ids
    end
  end
end
