defmodule Zaq.Agent.ZAQRouter do
  @moduledoc """
  Registers ZAQ Provider as a custom entry in the LLMDB catalog.

  ZAQ Provider is a LiteLLM gateway exposed through the User Portal. It appears
  in the provider list alongside openai/anthropic but routes all requests through
   the credential endpoint using the registered `Zaq.Agent.Providers.ZAQRouter`
   adapter for OpenAI-compatible generation/embeddings and LiteLLM reranking.

  The model list below is the default set advertised at startup. Call `reload/1`
  with a runtime list (e.g. from the portal `/models` response) to update it
  without restarting.

  This is the catalog of what the gateway *offers*. Whether a given deployment
  can actually reach it is a per-credential question answered by
  `Zaq.Agent.ProviderModels`, which filters this list through
  `ReqLLM.available_models/1` using the credential's API key.
  """

  @provider_id :zaq_router

  # First-run bootstrap defaults. Each must exist as a key in @default_models
  # (asserted at compile time below) so provisioning never wires a config that
  # points at a model the catalog doesn't advertise.
  @default_chat_model "openai/gpt-oss-120b"
  @default_embedding_model "baai/bge-m3"
  @default_embedding_dimension 1024
  @default_image_model "deepseek/deepseek-v4.1-flash"
  @default_translation_model "openai/gpt-oss-20b"
  @default_small_model "openai/gpt-oss-20b"
  @default_reranking_model "Qwen/Qwen3-Reranker-0.6B"
  @default_decision_model "typesafe/jev-1.14"

  @non_generative_caps %{
    chat: false,
    evaluate: false,
    embeddings: false,
    rerank: false,
    json: %{native: false, schema: false, strict: false},
    reasoning: %{enabled: false},
    streaming: %{text: false, tool_calls: false},
    tools: %{enabled: false, streaming: false, strict: false, parallel: false}
  }

  # Verified 2026-11-04 against https://openrouter.ai/api/v1/models?output_modalities=all.
  # Entries are {id, context, input, reasoning?, structured_json?}; tool support is explicit.
  @generation_models Map.new(
                       [
                         {"openai/gpt-oss-120b", 131_072, [:text], true, true},
                         {"openai/gpt-oss-20b", 131_072, [:text], true, true},
                         {"qwen/qwen3-235b-a22b-2507", 262_144, [:text], false, true},
                         {"qwen/qwen3-vl-235b-a22b-instruct", 262_144, [:text, :image], false,
                          true},
                         {"google/gemma-3-27b-it", 131_072, [:text, :image], false, true},
                         {"google/gemma-4-31b-it", 262_144, [:text, :image, :video], true, true},
                         {"google/gemini-2.5-flash-lite", 1_048_576,
                          [:text, :image, :audio, :video, :file], true, true},
                         {"nvidia/nemotron-3-nano-omni-30b-a3b-reasoning", 256_000,
                          [:text, :image, :audio, :video], true, false},
                         {"deepseek/deepseek-v4-pro", 1_048_576, [:text], true, true},
                         {"deepseek/deepseek-v4.1-flash", 1_048_576, [:text, :image], true, true},
                         {"moonshotai/kimi-k3", 1_048_576, [:text, :image, :video], true, true},
                         {"moonshotai/kimi-k3.1-pro", 1_048_576, [:text, :image, :video], true,
                          true},
                         {"z-ai/glm-5.3-flash", 1_048_576, [:text, :image, :video], true, true}
                       ],
                       fn {id, context, input, reasoning?, json?} ->
                         {id,
                          %{
                            limits: %{context: context},
                            modalities: %{input: input, output: [:text]},
                            capabilities: %{
                              chat: true,
                              evaluate: false,
                              embeddings: false,
                              rerank: false,
                              reasoning: %{enabled: reasoning?},
                              tools: %{enabled: true},
                              json: %{native: json?, schema: json?, strict: nil},
                              streaming: %{text: true, tool_calls: true}
                            }
                          }}
                       end
                     )

  # Dimensions/input limits: NVIDIA's model card, OpenAI embeddings guide,
  # ai.google.dev/gemini-api/docs/models/gemini-embedding-001 and BAAI/bge-m3's model card.
  @embedding_models Map.new(
                      [
                        {"nvidia/llama-nemotron-embed-vl-1b-v2", 10_240, [:text, :image], 2048,
                         2048},
                        {"openai/text-embedding-3-large", 8192, [:text], 1, 3072},
                        {"openai/text-embedding-3-small", 8192, [:text], 1, 1536},
                        {"google/gemini-embedding-001", 2048, [:text], 128, 3072},
                        {"baai/bge-m3", 8192, [:text], 1024, 1024}
                      ],
                      fn {id, context, input, min, dimensions} ->
                        {id,
                         %{
                           limits: %{context: context},
                           modalities: %{input: input, output: [:embeddings]},
                           capabilities:
                             Map.put(@non_generative_caps, :embeddings, %{
                               min_dimensions: min,
                               max_dimensions: dimensions,
                               default_dimensions: dimensions
                             })
                         }}
                      end
                    )

  @default_models @generation_models
                  |> Map.merge(@embedding_models)
                  |> Map.merge(%{
                    # https://docs.typesafe.ai/models: images/extended context require opt-in.
                    "typesafe/jev-1.14" => %{
                      limits: %{context: 65_536},
                      modalities: %{input: [:text, :image], output: [:decisions]},
                      capabilities: %{@non_generative_caps | evaluate: true},
                      catalog_only: false,
                      execution: %{
                        evaluate: %{
                          supported: true,
                          family: "typesafe_systemone",
                          wire_protocol: "typesafe_systemone",
                          transport: "http",
                          path: "/v1/systemone",
                          provider_model_id: "typesafe/jev-1.14"
                        }
                      }
                    },
                    # https://huggingface.co/Qwen/Qwen3-Reranker-0.6B
                    "Qwen/Qwen3-Reranker-0.6B" => %{
                      limits: %{context: 32_768},
                      modalities: %{input: [:text], output: [:rerank]},
                      capabilities: %{@non_generative_caps | rerank: true},
                      catalog_only: false,
                      execution: %{
                        rerank: %{
                          supported: true,
                          family: "cohere_rerank_compatible",
                          wire_protocol: "cohere_rerank",
                          transport: "http",
                          path: "/rerank",
                          provider_model_id: "Qwen/Qwen3-Reranker-0.6B"
                        }
                      }
                    }
                  })

  # Compile-time guard: the bootstrap default models must be real catalog entries.
  for model <- [
        @default_chat_model,
        @default_embedding_model,
        @default_image_model,
        @default_translation_model,
        @default_small_model,
        @default_reranking_model,
        @default_decision_model
      ] do
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

  @doc "Default knowledge-query translation model wired on first-run provisioning."
  @spec default_translation_model() :: String.t()
  def default_translation_model, do: @default_translation_model

  @doc "Default Small model wired on first-run provisioning for conversation titles."
  @spec default_small_model() :: String.t()
  def default_small_model, do: @default_small_model

  @doc "Default reranking model wired on first-run provisioning."
  @spec default_reranking_model() :: String.t()
  def default_reranking_model, do: @default_reranking_model

  @doc "Default decision model selection wired on first-run provisioning."
  @spec default_decision_model() :: String.t()
  def default_decision_model, do: @default_decision_model

  @doc """
  Returns the LiteLLM base URL configured for this deployment, or `nil` when the
  `:litellm_base_url` config is unset.

  Returning `nil` (rather than `""`) keeps the unset state detectable: callers
  that persist a credential let the `:endpoint` `validate_required` reject it with
  a clear changeset error instead of silently wiring an empty endpoint.
  """
  @spec default_endpoint() :: String.t() | nil
  def default_endpoint, do: Application.get_env(:zaq, :litellm_base_url)

  @doc "Returns the `LLMDB.load/1` opts that inject ZAQ Provider into the catalog."
  @spec llmdb_opts() :: keyword()
  def llmdb_opts, do: build_opts(@default_models)

  @doc """
  Re-loads LLMDB with an updated model list for ZAQ Provider.

  Pass a list of model ID strings returned by the User Portal. Known models keep
  their default catalog metadata, including context limits and capabilities.
  Unknown models retain the chat + tools fallback since the LiteLLM gateway
  handles capability negotiation at runtime; their context limit is unknown.

  Loader options such as `:snapshot_source` may be supplied for a scoped load.
  The ZAQ Router model overlay is always built from `model_ids`.
  """
  @spec reload([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def reload(model_ids, loader_opts \\ []) when is_list(model_ids) do
    models =
      Map.new(model_ids, fn id ->
        {id,
         Map.get(@default_models, id, %{capabilities: %{chat: true, tools: %{enabled: true}}})}
      end)

    LLMDB.load(Keyword.merge(loader_opts, build_opts(models)))
  end

  defp build_opts(models) do
    [
      custom: %{
        @provider_id => [
          name: "ZAQ Router",
          catalog_only: false,
          runtime: %{
            base_url: default_endpoint() || "https://llm.zaq.ai",
            auth: %{type: "bearer", env: []}
          },
          models: models
        ]
      }
    ]
  end
end
