defmodule Zaq.Agent.Providers.ZAQRouter do
  @moduledoc """
  ReqLLM provider for the ZAQ Router LiteLLM gateway.

  The gateway speaks the OpenAI Chat Completions protocol verbatim, so this
  module carries no custom encoding — `ReqLLM.Provider.Defaults` (applied by the
  `use ReqLLM.Provider` macro) supplies the full request/response pipeline. The
  module exists so `:zaq_router` is a real entry in the ReqLLM provider registry
  rather than being rewritten to `:openai` at the call site.

  Reranking delegates to ReqLLM's Cohere adapter with a request-local `/rerank`
  URL for LiteLLM. Only the temporary wire model uses `:cohere`; the catalog,
  credential and requested model ID are unchanged. Cohere's existing pipeline
  owns encoding, response decoding and transport hooks; ReqLLM owns batching and
  result normalization. Transport telemetry consequently identifies the Cohere
  protocol adapter, while ZAQ's configured credential remains the router's.

  This is registration for *execution* only. The model list and its capability
  metadata are a separate concern, owned by `Zaq.Agent.ZAQRouter`, which injects
  them into the LLMDB catalog via `LLMDB.load/1`. ReqLLM providers never declare
  models — both registrations are required and neither substitutes for the other.

  ## Base URL

  `default_base_url/0` is overridden to read `:litellm_base_url` at runtime,
  which `config/runtime.exs` populates from the `LITELLM_BASE_URL` environment
  variable. The `use` macro demands a compile-time literal, so the value passed
  there is only a fallback for the case where the config key is unset; it mirrors
  the same default `runtime.exs` applies.

  Callers normally pass `base_url` explicitly from the credential endpoint
  (`ReqLLM.Provider.Defaults` prefers `opts[:base_url]` over this default), so
  the runtime value applies only when a credential omits one.
  """

  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Providers.Cohere
  alias Zaq.Agent.ZAQRouter

  # Must be a literal — the `use` macro validates it with `is_binary/1` at
  # expansion time, so a module attribute or config lookup will not work here.
  use ReqLLM.Provider,
    id: :zaq_router,
    default_base_url: "https://llm.zaq.ai"

  use ReqLLM.Provider.Defaults

  @impl ReqLLM.Provider
  def prepare_request(:rerank, model_spec, input, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      opts =
        opts
        |> Keyword.put_new(:base_url, default_base_url())
        |> Keyword.update(:req_http_options, [url: "/rerank"], &Keyword.put(&1, :url, "/rerank"))

      Cohere.prepare_request(:rerank, %{model | provider: :cohere}, input, opts)
    end
  end

  def prepare_request(operation, model_spec, input, opts) do
    Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @doc """
  Returns the deployment's LiteLLM base URL from `:litellm_base_url`.

  Falls back to the compile-time default when the config key is unset.
  """
  @spec default_base_url() :: String.t()
  def default_base_url do
    ZAQRouter.default_endpoint() || "https://llm.zaq.ai"
  end
end
