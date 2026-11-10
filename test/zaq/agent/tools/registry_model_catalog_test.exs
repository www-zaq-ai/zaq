defmodule Zaq.Agent.Tools.RegistryModelCatalogTest do
  # These cases read or replace the catalog shared by all model lookups.
  use ExUnit.Case, async: false

  alias Zaq.Agent.Tools.Registry
  alias Zaq.TestSupport.ModelCatalogFixture

  test "model_tool_capability distinguishes unknown metadata" do
    assert Registry.model_tool_capability(nil, "gpt-4.1-mini") == :unknown
    assert Registry.model_tool_capability("openai", nil) == :unknown
    assert Registry.model_tool_capability("custom", "gpt-4.1-mini") == :unknown
    assert Registry.model_tool_capability("Custom", "gpt-4.1-mini") == :unknown
    assert Registry.model_tool_capability("not_a_provider", "not_a_model") == :unknown

    refute Registry.model_supports_tools?(nil, "gpt-4.1-mini")
    refute Registry.model_supports_tools?("openai", nil)
    refute Registry.model_supports_tools?("custom", "gpt-4.1-mini")
    refute Registry.model_supports_tools?("Custom", "gpt-4.1-mini")
    refute Registry.model_supports_tools?("not_a_provider", "not_a_model")
  end

  test "model_supports_tools? returns true for a known tools-capable model" do
    assert Registry.model_supports_tools?("openai", "gpt-4.1-mini")
    assert Registry.model_supports_tools?("OpenAI", "gpt-4.1-mini")
  end

  test "model_supports_tools? returns true for ReqLLM-only Codex model" do
    assert Registry.model_supports_tools?("openai_codex", "gpt-5.3-codex-spark")
  end

  test "model_supports_tools? handles map and nil capabilities with custom catalog" do
    snapshot = LLMDB.Store.snapshot()
    opts = LLMDB.Store.last_opts()
    source_before = Zaq.Config.get(:llm_db, :snapshot_source, :unset)

    on_exit(fn ->
      if snapshot, do: LLMDB.Store.put!(snapshot, opts), else: LLMDB.Store.clear!()
    end)

    catalog_opts = ModelCatalogFixture.minimal_source_opts!()

    {:ok, _snapshot} =
      LLMDB.load(
        catalog_opts ++
          [
            custom: %{
              test_provider: [
                name: "Test Provider",
                models: %{
                  "tools_map" => %{capabilities: %{tools: %{enabled: true}}},
                  "tools_disabled" => %{capabilities: %{tools: %{enabled: false}}}
                }
              ]
            }
          ]
      )

    assert Zaq.Config.get(:llm_db, :snapshot_source, :unset) == source_before

    assert Registry.model_supports_tools?("test_provider", "tools_map")
    assert Registry.model_tool_capability("test_provider", "tools_map") == :supported
    assert Registry.model_tool_capability("test_provider", "tools_disabled") == :unsupported
    refute Registry.model_supports_tools?("test_provider", "tools_disabled")
  end
end
