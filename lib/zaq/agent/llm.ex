defmodule Zaq.Agent.LLM do
  @moduledoc """
  Centralized LLM configuration reader.

  All agent modules (Retrieval, Answering, ChunkTitle) call this module
  instead of hardcoded environment variables or provider-specific modules.

  Supports any OpenAI-compatible API endpoint (Scaleway, OpenAI, Azure,
  Ollama, vLLM, LocalAI, llama.cpp).

  ## Configuration

  LLM settings are managed via the back-office UI at `/bo/system-config`
  and persisted in the database. All values are read directly from the
  database via `Zaq.System.get_llm_config/0`.
  """

  @doc """
  Base URL for the LLM API (without `/chat/completions` suffix).

  ## Examples

      iex> Zaq.Agent.LLM.endpoint()
      "https://api.scaleway.ai/v1"

      iex> Zaq.Agent.LLM.endpoint()
      "http://localhost:11434/v1"
  """
  def endpoint, do: Zaq.System.get_llm_config().endpoint

  @doc """
  API key for authentication. Empty string for local deployments
  that don't require authentication (e.g. Ollama).
  """
  def api_key, do: Zaq.System.get_llm_config().api_key || ""

  @doc """
  Model identifier. Provider-specific string.

  ## Examples

      "gpt-oss-120b"              # Scaleway
      "llama-3.3-70b-instruct"    # Ollama / vLLM
      "gpt-4o"                    # OpenAI
  """
  def model, do: Zaq.System.get_llm_config().model

  @doc "LLM sampling temperature. Default: 0.0 (deterministic)."
  def temperature, do: Zaq.System.get_llm_config().temperature

  @doc "Top-p (nucleus) sampling. Default: 0.9."
  def top_p, do: Zaq.System.get_llm_config().top_p

  @doc """
  Whether the LLM provider supports logprobs in the response.
  Used by the Answering agent for confidence scoring.
  When false, confidence calculation is skipped gracefully.
  """
  def supports_logprobs?, do: Zaq.System.get_llm_config().supports_logprobs

  @doc """
  Whether the LLM provider supports JSON response mode.
  Used by the Retrieval agent to force structured JSON output.
  When false, the agent will parse JSON from the text response.
  """
  def supports_json_mode?, do: Zaq.System.get_llm_config().supports_json_mode

  @doc """
  Returns the full configuration map. Useful for passing to
  LangChain's ChatOpenAI in a single call.

  ## Example

      config = Zaq.Agent.LLM.chat_config()
      # => %{
      #   model: "llama-3.3-70b-instruct",
      #   temperature: 0.0,
      #   top_p: 0.9,
      #   endpoint: "http://localhost:11434/v1/chat/completions",
      #   api_key: ""
      # }
  """
  def chat_config(overrides \\ []) do
    cfg = Zaq.System.get_llm_config()

    base = %{
      provider: cfg.provider,
      model: cfg.model,
      temperature: cfg.temperature,
      top_p: cfg.top_p,
      endpoint: cfg.endpoint <> cfg.path,
      api_key: cfg.api_key
    }

    Map.merge(base, Map.new(overrides))
  end

  @doc """
  Builds a LangChain chat model struct from an LLM config map.

  Dispatches to `ChatAnthropic` for `provider: "anthropic"`, and falls
  back to `ChatOpenAI` (which covers all OpenAI-compatible endpoints) for
  everything else.
  """
  def build_model(%{provider: "anthropic"} = config) do
    LangChain.ChatModels.ChatAnthropic.new!(%{
      model: config.model,
      temperature: config.temperature,
      api_key: config.api_key,
      endpoint: config.endpoint
    })
  end

  def build_model(config) do
    LangChain.ChatModels.ChatOpenAI.new!(config)
  end
end
