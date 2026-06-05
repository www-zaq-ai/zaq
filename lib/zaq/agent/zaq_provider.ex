defmodule Zaq.Agent.ZAQProvider do
  @moduledoc """
  Registers ZAQ Provider as a custom entry in the LLMDB catalog.

  ZAQ Provider is a LiteLLM gateway exposed through the User Portal. It appears
  in the provider list alongside openai/anthropic but routes all requests through
  the credential endpoint using the OpenAI-compatible protocol — `ProviderSpec`
  maps `:zaq_router` to `:openai` for ReqLLM routing.

  The model list below is the default set advertised at startup. Call `reload/1`
  with a runtime list (e.g. from the portal `/models` response) to update it
  without restarting.
  """

  @provider_id :zaq_router

  @vision_modalities %{input: [:image, :text, :video], output: [:text]}

  @default_models %{
    # Chat model
    "openai/gpt-oss-120b" => %{
      capabilities: %{chat: true, tools: %{enabled: true}}
    },
    # "owl-alpha" => %{
    #   capabilities: %{chat: true, tools: %{enabled: true}}
    # },
    # Vision models (appear in image-to-text config)
    # "gemma-4-26b-a4b-it" => %{
    #   capabilities: %{chat: true, tools: %{enabled: true}, reasoning: %{enabled: true}},
    #   modalities: @vision_modalities
    # },
    "google/gemma-4-31b-it" => %{
      capabilities: %{chat: true, tools: %{enabled: true}, reasoning: %{enabled: true}},
      modalities: @vision_modalities
    },
    # "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning" => %{
    #   capabilities: %{chat: true, tools: %{enabled: true}, reasoning: %{enabled: true}},
    #   modalities: %{input: [:image, :text, :video, :audio], output: [:text]}
    # },
    # "nvidia/nemotron-nano-12b-v2-vl" => %{
    #   capabilities: %{chat: true, tools: %{enabled: true}, reasoning: %{enabled: true}},
    #   modalities: @vision_modalities
    # },
    # Embedding model
    "nvidia/llama-nemotron-embed-vl-1b-v2" => %{
      capabilities: %{
        chat: false,
        embeddings: %{default_dimensions: 2048, max_dimensions: 2048},
        json: %{native: false, schema: false, strict: false},
        reasoning: %{enabled: false},
        streaming: %{text: false, tool_calls: false},
        tools: %{enabled: false}
      }
    }
  }

  @doc "Returns the LiteLLM base URL configured for this deployment."
  @spec default_endpoint() :: String.t()
  def default_endpoint, do: Application.get_env(:zaq, :litellm_base_url, "")

  @doc "Returns the `LLMDB.load/1` opts that inject ZAQ Provider into the catalog."
  @spec llmdb_opts() :: keyword()
  def llmdb_opts, do: build_opts(@default_models)

  @doc """
  Re-loads LLMDB with an updated model list for ZAQ Provider.

  Pass a list of model ID strings returned by the User Portal. Each model gets
  full chat + tools capabilities since the LiteLLM gateway handles capability
  negotiation at runtime.
  """
  @spec reload([String.t()]) :: {:ok, map()} | {:error, term()}
  def reload(model_ids) when is_list(model_ids) do
    models = Map.new(model_ids, &{&1, %{capabilities: %{chat: true, tools: %{enabled: true}}}})
    LLMDB.load(build_opts(models))
  end

  defp build_opts(models) do
    [custom: %{@provider_id => [name: "ZAQ Router", models: models]}]
  end
end
