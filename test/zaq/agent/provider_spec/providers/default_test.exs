defmodule Zaq.Agent.ProviderSpec.Providers.DefaultTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  alias Zaq.Agent.ProviderSpec.Providers.Default

  @malformed_inputs [0, 1.5, [], ~c"anthropic", %{}, {:provider, :anthropic}]

  describe "fixed_url_provider?/1" do
    test "returns false for non-atom and non-binary providers" do
      for input <- @malformed_inputs do
        assert Default.fixed_url_provider?(input) === false
      end
    end

    property "returns false for generated non-atom and non-binary providers" do
      check all(input <- non_atom_or_binary()) do
        assert Default.fixed_url_provider?(input) === false
      end
    end
  end

  describe "reqllm_provider/1" do
    test "falls back to openai for unsupported provider inputs" do
      for input <- @malformed_inputs do
        assert Default.reqllm_provider(input) === :openai
      end
    end

    test "resolves catalog-normalized Fireworks aliases" do
      assert {:ok, %LLMDB.Provider{catalog_only: false}} = LLMDB.provider(:fireworks_ai)
      assert {:ok, ReqLLM.Providers.FireworksAI} = ReqLLM.provider(:fireworks_ai)

      assert Default.reqllm_provider("fireworks-ai") === :fireworks_ai
      assert Default.reqllm_provider("fireworks.ai") === :fireworks_ai
    end

    property "falls back to openai for generated non-atom and non-binary providers" do
      check all(input <- non_atom_or_binary()) do
        assert Default.reqllm_provider(input) === :openai
      end
    end
  end

  defp non_atom_or_binary do
    one_of([
      integer(),
      float(),
      list_of(integer(), max_length: 5),
      tuple({integer(), integer()}),
      map_of(integer(), integer(), max_length: 5)
    ])
  end
end
