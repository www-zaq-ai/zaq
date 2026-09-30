defmodule Zaq.Agent.ZAQRouterTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.ProviderModels
  alias Zaq.Agent.ZAQRouter

  setup do
    on_exit(fn -> LLMDB.load() end)
    :ok
  end

  describe "reload/1" do
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

    test "ProviderModels exposes the registered catalog to an authenticated router credential" do
      assert {:ok, _} = ZAQRouter.reload(["openai/gpt-oss-120b", "deepseek/deepseek-v4-pro"])

      credential = %{
        provider: "zaq_router",
        endpoint: "https://llm.test/v1",
        api_key: "sk-test-123"
      }

      model_ids = credential |> ProviderModels.models_for_credential() |> Enum.map(& &1.id)

      assert "openai/gpt-oss-120b" in model_ids
      assert "deepseek/deepseek-v4-pro" in model_ids
    end
  end
end
