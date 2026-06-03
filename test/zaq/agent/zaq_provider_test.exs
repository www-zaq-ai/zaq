defmodule Zaq.Agent.ZAQProviderTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.ZAQProvider

  setup do
    on_exit(fn -> LLMDB.load() end)
    :ok
  end

  describe "reload/1" do
    test "non-empty list returns {:ok, _} and registers models in LLMDB" do
      assert {:ok, _snapshot} = ZAQProvider.reload(["model-a", "model-b"])

      model_ids = LLMDB.models(:zaq_provider) |> Enum.map(& &1.id)
      assert Enum.sort(model_ids) == Enum.sort(["model-a", "model-b"])

      for model <- LLMDB.models(:zaq_provider) do
        assert model.capabilities.chat == true
        assert model.capabilities.tools == %{enabled: true}
      end
    end

    test "empty list returns {:ok, _} and results in no models for :zaq_provider" do
      assert {:ok, _snapshot} = ZAQProvider.reload([])

      assert LLMDB.models(:zaq_provider) == []
    end

    test "second reload replaces previous catalog — does not append" do
      assert {:ok, _} = ZAQProvider.reload(["old-model"])
      assert {:ok, _} = ZAQProvider.reload(["new-model"])

      model_ids = LLMDB.models(:zaq_provider) |> Enum.map(& &1.id)
      assert model_ids == ["new-model"]
      refute "old-model" in model_ids
    end
  end
end
