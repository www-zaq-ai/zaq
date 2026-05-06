defmodule Zaq.Agent.Tools.RegistryTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.Tools.Registry

  test "tools returns expected whitelisted tool descriptors" do
    keys = Registry.tools() |> Enum.map(& &1.key)

    assert keys == [
             "basic.sleep",
             "basic.log",
             "basic.todo",
             "basic.random_sleep",
             "basic.increment",
             "basic.decrement",
             "basic.noop",
             "basic.inspect",
             "basic.today",
             "arithmetic.add",
             "arithmetic.subtract",
             "arithmetic.multiply",
             "arithmetic.divide",
             "arithmetic.square",
             "advanced.lua_eval",
             "answering.search_knowledge_base",
             "answering.list_knowledge_base_files"
           ]
  end

  test "valid_tool_key? validates known and unknown keys" do
    assert Registry.valid_tool_key?("basic.sleep")
    refute Registry.valid_tool_key?("files.unknown")
    refute Registry.valid_tool_key?(nil)
  end

  test "keys returns whitelisted keys" do
    assert Registry.keys() == [
             "basic.sleep",
             "basic.log",
             "basic.todo",
             "basic.random_sleep",
             "basic.increment",
             "basic.decrement",
             "basic.noop",
             "basic.inspect",
             "basic.today",
             "arithmetic.add",
             "arithmetic.subtract",
             "arithmetic.multiply",
             "arithmetic.divide",
             "arithmetic.square",
             "advanced.lua_eval",
             "answering.search_knowledge_base",
             "answering.list_knowledge_base_files"
           ]
  end

  test "resolve_modules returns mapped modules in key order" do
    assert {:ok, modules} =
             Registry.resolve_modules([
               "basic.sleep",
               "basic.log",
               "arithmetic.add",
               "advanced.lua_eval",
               "arithmetic.multiply",
               "arithmetic.multiply"
             ])

    assert modules == [
             Jido.Tools.Basic.Sleep,
             Jido.Tools.Basic.Log,
             Jido.Tools.Arithmetic.Add,
             Jido.Tools.LuaEval,
             Jido.Tools.Arithmetic.Multiply
           ]
  end

  test "resolve_modules returns unknown tool keys" do
    assert {:error, {:unknown_tools, ["files.unknown", "other.missing"]}} =
             Registry.resolve_modules(["files.unknown", "basic.sleep", "other.missing"])
  end

  test "resolve_modules on non-list input returns empty unknown set" do
    assert {:error, {:unknown_tools, []}} = Registry.resolve_modules("files.read_file")
  end

  test "model_supports_tools? treats unknown or missing values as false" do
    refute Registry.model_supports_tools?(nil, "gpt-4.1-mini")
    refute Registry.model_supports_tools?("openai", nil)
    refute Registry.model_supports_tools?("custom", "gpt-4.1-mini")
    refute Registry.model_supports_tools?("not_a_provider", "not_a_model")
  end

  test "model_supports_tools? returns true for a known tools-capable model" do
    assert Registry.model_supports_tools?("openai", "gpt-4.1-mini")
  end

  test "model_supports_tools? handles map and nil capabilities with custom catalog" do
    {:ok, _snapshot} =
      LLMDB.load(
        custom: %{
          test_provider: [
            name: "Test Provider",
            models: %{
              "tools_map" => %{capabilities: %{tools: %{enabled: true}}}
            }
          ]
        }
      )

    on_exit(fn ->
      {:ok, _} = LLMDB.load()
    end)

    assert Registry.model_supports_tools?("test_provider", "tools_map")
  end
end
