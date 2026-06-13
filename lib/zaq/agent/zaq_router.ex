defmodule Zaq.Agent.ZAQRouter do
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

  # First-run bootstrap defaults. Each must exist as a key in @default_models
  # (asserted at compile time below) so provisioning never wires a config that
  # points at a model the catalog doesn't advertise.
  @default_chat_model "openai/gpt-oss-120b"
  @default_embedding_model "nvidia/llama-nemotron-embed-vl-1b-v2"
  @default_embedding_dimension 2048
  @default_image_model "nvidia/nemotron-nano-12b-v2-vl"

  @vision_modalities %{input: [:image, :text], output: [:text]}

  @embedding_caps_3072 %{
    chat: false,
    embeddings: %{default_dimensions: 3072, max_dimensions: 3072},
    json: %{native: false, schema: false, strict: false},
    reasoning: %{enabled: false},
    streaming: %{text: false, tool_calls: false},
    tools: %{enabled: false}
  }

  @default_models %{
    # ── LLM / Chat models ──────────────────────────────────────────────
    # Free
    "openai/gpt-oss-120b" => %{
      capabilities: %{chat: true, tools: %{enabled: true}, reasoning: %{enabled: true}}
    },
    "qwen/qwen3-235b-a22b-2507" => %{
      capabilities: %{chat: true, tools: %{enabled: true}}
    },
    "mistralai/mistral-small-2603" => %{
      capabilities: %{chat: true, tools: %{enabled: true}, reasoning: %{enabled: true}},
      modalities: @vision_modalities
    },
    "deepseek/deepseek-v4-pro" => %{
      capabilities: %{chat: true, tools: %{enabled: true}, reasoning: %{enabled: true}}
    },

    # ── Vision models (image-to-text) ──────────────────────────────────
    "nvidia/nemotron-nano-12b-v2-vl" => %{
      capabilities: %{chat: true, tools: %{enabled: true}, reasoning: %{enabled: true}},
      modalities: @vision_modalities
    },
    "google/gemma-3-27b-it" => %{
      capabilities: %{chat: true, tools: %{enabled: true}},
      modalities: @vision_modalities
    },
    "google/gemini-2.5-flash-lite" => %{
      capabilities: %{chat: true, tools: %{enabled: true}, reasoning: %{enabled: true}},
      modalities: @vision_modalities
    },
    "qwen/qwen3-vl-235b-a22b-instruct" => %{
      capabilities: %{chat: true, tools: %{enabled: true}},
      modalities: @vision_modalities
    },

    # ── Embedding models ───────────────────────────────────────────────
    "nvidia/llama-nemotron-embed-vl-1b-v2" => %{
      capabilities: %{
        chat: false,
        embeddings: %{default_dimensions: 2048, max_dimensions: 2048},
        json: %{native: false, schema: false, strict: false},
        reasoning: %{enabled: false},
        streaming: %{text: false, tool_calls: false},
        tools: %{enabled: false}
      }
    },
    "openai/text-embedding-3-small" => %{
      capabilities: %{
        chat: false,
        embeddings: %{default_dimensions: 1536, max_dimensions: 1536},
        json: %{native: false, schema: false, strict: false},
        reasoning: %{enabled: false},
        streaming: %{text: false, tool_calls: false},
        tools: %{enabled: false}
      }
    },
    "google/gemini-embedding-001" => %{capabilities: @embedding_caps_3072},
    "openai/text-embedding-3-large" => %{capabilities: @embedding_caps_3072}
  }

  # Compile-time guard: the bootstrap default models must be real catalog entries.
  for model <- [@default_chat_model, @default_embedding_model, @default_image_model] do
    unless Map.has_key?(@default_models, model) do
      raise "ZAQRouter default model #{inspect(model)} is not present in @default_models"
    end
  end

  @doc "Default chat/LLM model wired on first-run provisioning."
  @spec default_chat_model() :: String.t()
  def default_chat_model, do: @default_chat_model

  @doc "Default embedding model and its dimension wired on first-run provisioning."
  @spec default_embedding_model() :: {String.t(), pos_integer()}
  def default_embedding_model, do: {@default_embedding_model, @default_embedding_dimension}

  @doc "Default image-to-text model wired on first-run provisioning."
  @spec default_image_model() :: String.t()
  def default_image_model, do: @default_image_model

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
