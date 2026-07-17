defmodule Zaq.Agent.Tools.RegistryTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.Tools.Registry

  test "tools returns expected whitelisted tool descriptors" do
    keys = Registry.tools() |> Enum.map(& &1.key)

    assert keys == [
             "accounts.fetch_history",
             "answering.search_knowledge_base",
             "answering.knowledge_base_overview",
             "conversation.persist_message_history",
             "data_source.get_document",
             "data_source.list_documents",
             "data_source.search_documents",
             "data_source.download_document",
             "data_source.create_document",
             "data_source.update_document",
             "data_source.get_sheet",
             "data_source.inspect_sheet",
             "data_source.create_sheet",
             "data_source.add_sheet_tab",
             "data_source.update_sheet_values",
             "data_source.append_sheet_values",
             "data_source.clear_sheet_values",
             "data_source.delete_sheet_tab",
             "files.create_file",
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
             "workflow.condition",
             "workflow.run_agent",
             "workflow.to_utc_datetime",
             "workflow.schedule_action",
             "workflow.dispatch_event",
             "web.browsing",
             "advanced.lua_eval",
             "skills.load_skill"
           ]
  end

  test "valid_tool_key? validates known and unknown keys" do
    assert Registry.valid_tool_key?("basic.sleep")
    refute Registry.valid_tool_key?("files.unknown")
    refute Registry.valid_tool_key?(nil)
  end

  test "every registered tool has valid NimbleOptions param and output schemas" do
    # The chat tool-exec path (Jido.Action.Exec) builds NimbleOptions from
    # these at call time — an invalid type (e.g. bare :list) only explodes in
    # production. Validate the whole catalog here.
    for %{key: key, module: module} <- Registry.tools() do
      if function_exported?(module, :schema, 0) do
        assert %NimbleOptions{} = NimbleOptions.new!(module.schema()), "invalid schema: #{key}"
      end

      if function_exported?(module, :output_schema, 0) do
        assert %NimbleOptions{} = NimbleOptions.new!(module.output_schema()),
               "invalid output_schema: #{key}"
      end
    end
  end

  test "every registered tool module is loadable and runnable" do
    for %{key: key, module: module} <- Registry.tools() do
      assert Code.ensure_loaded?(module),
             "registered module for #{key} does not exist: #{inspect(module)}"

      assert function_exported?(module, :run, 2), "registered module for #{key} is not runnable"
    end
  end

  test "fetch_history descriptor resolves to a runnable, self-access-documented module" do
    assert {:ok, [Zaq.Agent.Tools.Accounts.History]} =
             Registry.resolve_modules(["accounts.fetch_history"])

    descriptor = Enum.find(Registry.tools(), &(&1.key == "accounts.fetch_history"))
    assert descriptor.description =~ "self-access only"
    assert Code.ensure_loaded?(descriptor.module)
    assert function_exported?(descriptor.module, :run, 2)
  end

  test "workflow.run_agent resolves to the RunAgent tool so agents can run other agents" do
    assert Registry.valid_tool_key?("workflow.run_agent")

    assert {:ok, [Zaq.Agent.Tools.Workflow.RunAgent]} =
             Registry.resolve_modules(["workflow.run_agent"])
  end

  test "conversation.persist_message_history resolves to the message history tool" do
    assert Registry.valid_tool_key?("conversation.persist_message_history")

    assert {:ok, [Zaq.Agent.Tools.Conversations.PersistMessageHistory]} =
             Registry.resolve_modules(["conversation.persist_message_history"])
  end

  test "web.browsing resolves to the browsing tool" do
    assert Registry.valid_tool_key?("web.browsing")

    assert {:ok, [Zaq.Agent.Tools.Web.Browsing]} =
             Registry.resolve_modules(["web.browsing"])
  end

  test "keys returns whitelisted keys" do
    assert Registry.keys() == [
             "accounts.fetch_history",
             "answering.search_knowledge_base",
             "answering.knowledge_base_overview",
             "conversation.persist_message_history",
             "data_source.get_document",
             "data_source.list_documents",
             "data_source.search_documents",
             "data_source.download_document",
             "data_source.create_document",
             "data_source.update_document",
             "data_source.get_sheet",
             "data_source.inspect_sheet",
             "data_source.create_sheet",
             "data_source.add_sheet_tab",
             "data_source.update_sheet_values",
             "data_source.append_sheet_values",
             "data_source.clear_sheet_values",
             "data_source.delete_sheet_tab",
             "files.create_file",
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
             "workflow.condition",
             "workflow.run_agent",
             "workflow.to_utc_datetime",
             "workflow.schedule_action",
             "workflow.dispatch_event",
             "web.browsing",
             "advanced.lua_eval",
             "skills.load_skill"
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

  test "ghost_keys returns keys not in the registry" do
    assert Registry.ghost_keys(["basic.sleep", "removed.old_tool", "files.unknown"]) ==
             ["removed.old_tool", "files.unknown"]
  end

  test "ghost_keys returns empty list when all keys are valid" do
    assert Registry.ghost_keys(["basic.sleep", "basic.log"]) == []
  end

  test "ghost_keys returns empty list for empty input" do
    assert Registry.ghost_keys([]) == []
  end

  test "ghost_keys returns empty list for non-list input" do
    assert Registry.ghost_keys(nil) == []
    assert Registry.ghost_keys("basic.sleep") == []
  end

  test "model_supports_tools? treats unknown or missing values as false" do
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
