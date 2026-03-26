defmodule Zaq.Agent.LLM do
  @moduledoc """
  Centralized LLM configuration reader.

  All agent modules (Retrieval, Answering, ChunkTitle) call this module
  instead of hardcoded environment variables or provider-specific modules.

  Supports any OpenAI-compatible API endpoint (Scaleway, OpenAI, Azure,
  Ollama, vLLM, LocalAI, llama.cpp).

  ## Configuration

  LLM settings are managed via the back-office UI at `/bo/system-config`
  and persisted in the database. The application env is kept in sync
  automatically via `Zaq.System.apply_llm_to_app_env/0`.
  """

  @doc """
  Base URL for the LLM API (without `/chat/completions` suffix).

  ## Examples

      iex> Zaq.Agent.LLM.endpoint()
      "https://api.scaleway.ai/v1"

      iex> Zaq.Agent.LLM.endpoint()
      "http://localhost:11434/v1"
  """
  def endpoint, do: config(:endpoint)

  @doc """
  API key for authentication. Empty string for local deployments
  that don't require authentication (e.g. Ollama).
  """
  def api_key, do: config(:api_key, "")

  @doc """
  Model identifier. Provider-specific string.

  ## Examples

      "gpt-oss-120b"              # Scaleway
      "llama-3.3-70b-instruct"    # Ollama / vLLM
      "gpt-4o"                    # OpenAI
  """
  def model, do: config(:model, "llama-3.3-70b-instruct")

  @doc "LLM sampling temperature. Default: 0.0 (deterministic)."
  def temperature, do: config(:temperature, 0.0)

  @doc "Top-p (nucleus) sampling. Default: 0.9."
  def top_p, do: config(:top_p, 0.9)

  @doc """
  Whether the LLM provider supports logprobs in the response.
  Used by the Answering agent for confidence scoring.
  When false, confidence calculation is skipped gracefully.
  """
  def supports_logprobs?, do: config(:supports_logprobs, true)

  @doc """
  Whether the LLM provider supports JSON response mode.
  Used by the Retrieval agent to force structured JSON output.
  When false, the agent will parse JSON from the text response.
  """
  def supports_json_mode?, do: config(:supports_json_mode, true)

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
    base = %{
      model: model(),
      temperature: temperature(),
      top_p: top_p(),
      endpoint: endpoint() <> "/chat/completions",
      api_key: api_key()
    }

    Map.merge(base, Map.new(overrides))
  end

  # -- Private --

  defp config(key, default \\ nil) do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
