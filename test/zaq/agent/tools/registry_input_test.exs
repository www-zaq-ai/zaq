defmodule Zaq.Agent.Tools.RegistryInputTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.Tools.Registry

  test "invalid provider only returns unknown capability and false support" do
    assert Registry.model_tool_capability(:openai, "gpt-4.1-mini") === :unknown
    assert Registry.model_supports_tools?(:openai, "gpt-4.1-mini") === false
  end

  test "invalid model only returns unknown capability and false support" do
    assert Registry.model_tool_capability("openai", 123) === :unknown
    assert Registry.model_supports_tools?("openai", 123) === false
  end

  test "both identifiers invalid return unknown capability and false support" do
    assert Registry.model_tool_capability(%{}, []) === :unknown
    assert Registry.model_supports_tools?(%{}, []) === false
  end

  property "invalid providers return unknown capability and false support" do
    check all(provider <- invalid_identifier(), max_runs: 100) do
      assert Registry.model_tool_capability(provider, "gpt-4.1-mini") === :unknown
      assert Registry.model_supports_tools?(provider, "gpt-4.1-mini") === false
    end
  end

  property "invalid models return unknown capability and false support" do
    check all(model <- invalid_identifier(), max_runs: 100) do
      assert Registry.model_tool_capability("openai", model) === :unknown
      assert Registry.model_supports_tools?("openai", model) === false
    end
  end

  defp invalid_identifier do
    StreamData.one_of([
      integer(),
      member_of([:openai, true, false]),
      list_of(integer(), max_length: 5),
      constant(%{})
    ])
  end
end
