defmodule Zaq.Agent.LLMTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.LLM

  describe "config readers" do
    setup do
      # Store original config and restore after each test
      original = Application.get_env(:zaq, LLM)

      on_exit(fn ->
        if original do
          Application.put_env(:zaq, LLM, original)
        else
          Application.delete_env(:zaq, LLM)
        end
      end)

      :ok
    end

    test "reads endpoint from config" do
      Application.put_env(:zaq, LLM, endpoint: "https://api.example.com/v1")
      assert LLM.endpoint() == "https://api.example.com/v1"
    end

    test "reads api_key from config, defaults to empty string" do
      Application.put_env(:zaq, LLM, [])
      assert LLM.api_key() == ""
    end

    test "reads api_key when set" do
      Application.put_env(:zaq, LLM, api_key: "sk-test-123")
      assert LLM.api_key() == "sk-test-123"
    end

    test "reads model from config with default" do
      Application.put_env(:zaq, LLM, [])
      assert LLM.model() == "llama-3.3-70b-instruct"
    end

    test "reads model when set" do
      Application.put_env(:zaq, LLM, model: "gpt-4o")
      assert LLM.model() == "gpt-4o"
    end

    test "reads temperature with default 0.0" do
      Application.put_env(:zaq, LLM, [])
      assert LLM.temperature() == 0.0
    end

    test "reads top_p with default 0.9" do
      Application.put_env(:zaq, LLM, [])
      assert LLM.top_p() == 0.9
    end

    test "reads supports_logprobs? with default true" do
      Application.put_env(:zaq, LLM, [])
      assert LLM.supports_logprobs?() == true
    end

    test "supports_logprobs? returns false when configured" do
      Application.put_env(:zaq, LLM, supports_logprobs: false)
      assert LLM.supports_logprobs?() == false
    end

    test "reads supports_json_mode? with default true" do
      Application.put_env(:zaq, LLM, [])
      assert LLM.supports_json_mode?() == true
    end

    test "supports_json_mode? returns false when configured" do
      Application.put_env(:zaq, LLM, supports_json_mode: false)
      assert LLM.supports_json_mode?() == false
    end
  end

  describe "chat_config/1" do
    setup do
      original = Application.get_env(:zaq, LLM)

      Application.put_env(:zaq, LLM,
        endpoint: "https://api.example.com/v1",
        api_key: "sk-test",
        model: "test-model",
        temperature: 0.1,
        top_p: 0.8
      )

      on_exit(fn ->
        if original do
          Application.put_env(:zaq, LLM, original)
        else
          Application.delete_env(:zaq, LLM)
        end
      end)

      :ok
    end

    test "returns full config map with /chat/completions appended" do
      config = LLM.chat_config()

      assert config.endpoint == "https://api.example.com/v1/chat/completions"
      assert config.api_key == "sk-test"
      assert config.model == "test-model"
      assert config.temperature == 0.1
      assert config.top_p == 0.8
    end

    test "allows overrides" do
      config = LLM.chat_config(model: "override-model", temperature: 0.5)

      assert config.model == "override-model"
      assert config.temperature == 0.5
      # Non-overridden values stay
      assert config.api_key == "sk-test"
    end
  end
end
