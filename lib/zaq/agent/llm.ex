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
  Returns a ReqLLM inline model spec map from the system LLM config.

  Uses `cfg.endpoint` directly as `base_url` — do NOT append `cfg.path`
  (ReqLLM appends the provider path itself). Anthropic uses its own default
  API URL so no `base_url` is set for that provider.
  """
  # Providers natively supported by ReqLLM. Everything else is OpenAI-compatible.
  @reqllm_providers ~w(openai anthropic google xai mistral)

  # Providers that manage their own API URLs inside ReqLLM — never override with base_url.
  # OpenAI is excluded: it supports custom endpoints (Azure, proxies, Scaleway, etc.)
  @fixed_url_providers ~w(anthropic google xai mistral)

  def build_model_spec do
    cfg = Zaq.System.get_llm_config()
    provider = reqllm_provider(cfg.provider)

    %{provider: provider, id: cfg.model}
    |> maybe_put_base_url(cfg)
  end

  defp reqllm_provider(p) when p in @reqllm_providers, do: String.to_atom(p)
  defp reqllm_provider(_), do: :openai

  defp maybe_put_base_url(spec, %{provider: p}) when p in @fixed_url_providers, do: spec

  defp maybe_put_base_url(spec, %{endpoint: url}) when is_binary(url) and url != "",
    do: Map.put(spec, :base_url, url)

  defp maybe_put_base_url(spec, _), do: spec

  @doc "Sampling opts for ReqLLM generation calls. Includes api_key when configured."
  def generation_opts do
    cfg = Zaq.System.get_llm_config()
    opts = [temperature: cfg.temperature, top_p: cfg.top_p]

    opts =
      if is_binary(cfg.api_key) and cfg.api_key != "" do
        Keyword.put(opts, :api_key, cfg.api_key)
      else
        opts
      end

    if cfg.supports_logprobs do
      Keyword.put(opts, :provider_options, openai_logprobs: true)
    else
      opts
    end
  end
end
