defmodule Zaq.Agent.AgentSamplingPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.{ConfiguredAgent, ProviderSpec}

  property "dedicated sampling always wins over JSON sampling while unrelated options survive" do
    check all(
            temperature <- StreamData.integer(0..200),
            top_p <- StreamData.integer(1..100),
            tokens <- StreamData.positive_integer()
          ) do
      agent = %ConfiguredAgent{
        temperature: temperature / 100,
        top_p: top_p / 100,
        advanced_options: %{"temperature" => 8, "top_p" => -1, "max_tokens" => tokens}
      }

      assert {:ok, opts} = ProviderSpec.llm_opts(agent, nil)
      assert opts[:temperature] == agent.temperature
      assert opts[:top_p] == agent.top_p
      assert opts[:max_tokens] == tokens
    end
  end
end
