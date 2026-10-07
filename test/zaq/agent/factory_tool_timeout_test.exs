defmodule Zaq.Agent.FactoryToolTimeoutTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Agent.Strategy.State
  alias Zaq.Agent.Factory
  alias Zaq.Agent.Tools.SearchKnowledgeBase
  alias Zaq.Agent.Tools.Web.Browsing

  test "the effective worker config receives the declared budget" do
    agent = Factory.new(state: %{model: "openai:gpt-4.1-mini"})
    {agent, _} = Factory.cmd(agent, {:ai_react_register_tool, %{tool_module: Browsing}})
    {agent, _} = Factory.cmd(agent, {:ai_react_start, %{query: "hello", request_id: "budget"}})

    assert State.get(agent).pending_worker_start.config.tool_exec.timeout_ms ==
             Browsing.tool_timeout_ms()

    assert agent.state.requests["budget"].status == :pending
  end

  property "live tool registration order and duplicates do not change the required budget" do
    check all(tools <- list_of(member_of([Browsing, SearchKnowledgeBase]), max_length: 8)) do
      expected =
        Enum.reduce(tools, 15_000, fn tool, budget ->
          max(tool.tool_timeout_ms(), budget)
        end)

      reordered = tools |> Enum.reverse() |> Enum.uniq()

      for registrations <- [tools, reordered] do
        started = start_with_tools(registrations)
        assert State.get(started).pending_worker_start.config.tool_exec.timeout_ms == expected
      end
    end
  end

  test "removing the last declaring tool restores the ordinary budget on the next request" do
    agent = Factory.new(state: %{model: "openai:gpt-4.1-mini"})
    {agent, _} = Factory.cmd(agent, {:ai_react_register_tool, %{tool_module: Browsing}})
    {:ok, agent, _} = Factory.on_before_cmd(agent, {:ai_react_start, %{query: "first"}})
    assert Jido.AI.get_strategy_config(agent).tool_timeout_ms == Browsing.tool_timeout_ms()

    {agent, _} = Factory.cmd(agent, {:ai_react_unregister_tool, %{tool_name: Browsing.name()}})
    {agent, _} = Factory.cmd(agent, {:ai_react_start, %{query: "second"}})
    assert State.get(agent).pending_worker_start.config.tool_exec.timeout_ms == 15_000
  end

  test "removing the highest declaring tool falls back to the remaining budget before the default" do
    agent = Factory.new(state: %{model: "openai:gpt-4.1-mini"})
    {agent, _} = Factory.cmd(agent, {:ai_react_register_tool, %{tool_module: Browsing}})

    {agent, _} =
      Factory.cmd(agent, {:ai_react_register_tool, %{tool_module: SearchKnowledgeBase}})

    {:ok, agent, _} = Factory.on_before_cmd(agent, {:ai_react_start, %{query: "first"}})
    assert Jido.AI.get_strategy_config(agent).tool_timeout_ms == 120_000

    {agent, _} =
      Factory.cmd(agent, {:ai_react_unregister_tool, %{tool_name: SearchKnowledgeBase.name()}})

    {:ok, agent, _} = Factory.on_before_cmd(agent, {:ai_react_start, %{query: "second"}})
    assert Jido.AI.get_strategy_config(agent).tool_timeout_ms == Browsing.tool_timeout_ms()

    {agent, _} = Factory.cmd(agent, {:ai_react_unregister_tool, %{tool_name: Browsing.name()}})
    {agent, _} = Factory.cmd(agent, {:ai_react_start, %{query: "third"}})
    assert State.get(agent).pending_worker_start.config.tool_exec.timeout_ms == 15_000
  end

  defp start_with_tools(tools) do
    agent = Factory.new(state: %{model: "openai:gpt-4.1-mini"})

    agent =
      Enum.reduce(tools, agent, fn tool, agent ->
        {agent, _} = Factory.cmd(agent, {:ai_react_register_tool, %{tool_module: tool}})
        agent
      end)

    {started, _} = Factory.cmd(agent, {:ai_react_start, %{query: "hello"}})
    started
  end
end
