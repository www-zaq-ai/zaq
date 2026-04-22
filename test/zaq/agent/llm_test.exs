defmodule Zaq.Agent.LLMTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.LLM
  alias Zaq.SystemConfigFixtures

  defp seed_llm(attrs) do
    params =
      Map.merge(
        %{
          model: "llama-3.3-70b-instruct",
          endpoint: "http://localhost:11434/v1",
          temperature: 0.0,
          top_p: 0.9,
          supports_logprobs: true,
          supports_json_mode: true
        },
        attrs
      )

    SystemConfigFixtures.seed_llm_config(params)
    :ok
  end

  describe "config readers" do
    test "reads endpoint from config" do
      seed_llm(%{endpoint: "https://api.example.com/v1"})
      assert LLM.endpoint() == "https://api.example.com/v1"
    end

    test "reads api_key, defaults to empty string" do
      assert LLM.api_key() == ""
    end

    test "reads model with default" do
      assert LLM.model() == "llama-3.3-70b-instruct"
    end

    test "reads model when set" do
      seed_llm(%{model: "gpt-4o"})
      assert LLM.model() == "gpt-4o"
    end

    test "reads temperature with default 0.0" do
      assert LLM.temperature() == 0.0
    end

    test "reads top_p with default 0.9" do
      assert LLM.top_p() == 0.9
    end

    test "reads supports_logprobs? with default true" do
      assert LLM.supports_logprobs?() == true
    end

    test "supports_logprobs? returns false when configured" do
      seed_llm(%{supports_logprobs: false})
      assert LLM.supports_logprobs?() == false
    end

    test "reads supports_json_mode? with default true" do
      assert LLM.supports_json_mode?() == true
    end

    test "supports_json_mode? returns false when configured" do
      seed_llm(%{supports_json_mode: false})
      assert LLM.supports_json_mode?() == false
    end
  end

  describe "build_model_spec/0" do
    setup do
      seed_llm(%{
        endpoint: "https://api.example.com/v1",
        model: "test-model",
        temperature: 0.1,
        top_p: 0.8
      })

      :ok
    end

    test "returns model spec with provider, id, and base_url" do
      spec = LLM.build_model_spec()

      # unknown providers (e.g. "custom") map to :openai (OpenAI-compatible)
      assert spec.provider == :openai
      assert spec.id == "test-model"
      assert spec.base_url == "https://api.example.com/v1"
    end

    test "generation_opts returns temperature and top_p" do
      opts = LLM.generation_opts()

      assert opts[:temperature] == 0.1
      assert opts[:top_p] == 0.8
    end
  end
end
