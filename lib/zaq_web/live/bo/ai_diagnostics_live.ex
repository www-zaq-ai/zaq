defmodule ZaqWeb.Live.BO.AIDiagnosticsLive do
  use ZaqWeb, :live_view

  alias Zaq.Agent.{LLM, PromptTemplate, TokenEstimator}
  alias Zaq.Embedding.Client, as: EmbeddingClient
  alias Zaq.Ingestion.{Chunk, Document}

  @modules [
    # Phase 1
    %{
      phase: "1",
      name: "Zaq.Agent.LLM",
      file: "lib/zaq/agent/llm.ex",
      description: "LLM config & chat wrapper"
    },
    %{
      phase: "1",
      name: "Zaq.Embedding.Client",
      file: "lib/zaq/embedding/client.ex",
      description: "OpenAI-compatible embedding HTTP client"
    },
    %{
      phase: "1",
      name: "Zaq.Agent.PromptTemplate",
      file: "lib/zaq/agent/prompt_template.ex",
      description: "DB-managed system prompts"
    },
    %{
      phase: "1",
      name: "Zaq.Ingestion.Document",
      file: "lib/zaq/ingestion/document.ex",
      description: "Document Ecto schema"
    },
    %{
      phase: "1",
      name: "Zaq.Ingestion.Chunk",
      file: "lib/zaq/ingestion/chunk.ex",
      description: "Chunk schema with pgvector halfvec column"
    },
    # Phase 2
    %{
      phase: "2",
      name: "Zaq.Agent.PromptGuard",
      file: "lib/zaq/agent/prompt_guard.ex",
      description: "Input/output safety guard"
    },
    %{
      phase: "2",
      name: "Zaq.Agent.LogprobsAnalyzer",
      file: "lib/zaq/agent/logprobs_analyzer.ex",
      description: "Confidence scoring via logprobs"
    },
    %{
      phase: "2",
      name: "Zaq.Agent.TokenEstimator",
      file: "lib/zaq/agent/token_estimator.ex",
      description: "Token estimation (words x 1.3)"
    },
    %{
      phase: "2",
      name: "Zaq.Agent.Retrieval",
      file: "lib/zaq/agent/retrieval.ex",
      description: "Query rewriting via LLM + hybrid search"
    },
    %{
      phase: "2",
      name: "Zaq.Agent.Answering",
      file: "lib/zaq/agent/answering.ex",
      description: "Response generation with confidence scoring"
    },
    %{
      phase: "2",
      name: "Zaq.Agent.ChunkTitle",
      file: "lib/zaq/agent/chunk_title.ex",
      description: "LLM-powered chunk title generation"
    }
  ]

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/bo/ai-diagnostics",
       modules: @modules,
       llm_config: load_llm_config(),
       embedding_config: load_embedding_config(),
       ingestion_config: load_ingestion_config(),
       llm_status: :idle,
       embedding_status: :idle,
       token_test_result: nil,
       prompt_templates: load_prompt_templates(),
       document_count: document_count(),
       chunk_count: chunk_count()
     )}
  end

  def handle_event("test_llm", _params, socket) do
    socket = assign(socket, llm_status: :loading)

    cfg = LLM.chat_config()

    status =
      try do
        case Req.post(cfg.endpoint,
               json: %{
                 model: cfg.model,
                 temperature: cfg.temperature,
                 top_p: cfg.top_p,
                 messages: [%{role: "user", content: "ping"}],
                 max_tokens: 1
               },
               headers: [{"authorization", "Bearer #{cfg.api_key}"}],
               receive_timeout: 10_000
             ) do
          {:ok, %{status: 200}} -> :ok
          {:ok, %{status: code}} -> {:error, "HTTP #{code}"}
          {:error, reason} -> {:error, inspect(reason)}
        end
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:noreply, assign(socket, llm_status: status)}
  end

  def handle_event("test_embedding", _params, socket) do
    socket = assign(socket, embedding_status: :loading)

    status =
      try do
        case EmbeddingClient.embed("ping") do
          {:ok, _vector} -> :ok
          {:error, reason} -> {:error, inspect(reason)}
        end
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:noreply, assign(socket, embedding_status: status)}
  end

  def handle_event("test_token_estimator", _params, socket) do
    sample = "The quick brown fox jumps over the lazy dog"
    result = TokenEstimator.estimate(sample)
    {:noreply, assign(socket, token_test_result: result)}
  end

  # --- Private helpers ---

  defp load_llm_config do
    %{
      endpoint: LLM.endpoint() || "not set",
      model: LLM.model(),
      temperature: LLM.temperature(),
      top_p: LLM.top_p(),
      supports_logprobs: LLM.supports_logprobs?(),
      supports_json_mode: LLM.supports_json_mode?()
    }
  end

  defp load_embedding_config do
    cfg = Application.get_env(:zaq, EmbeddingClient, [])

    %{
      endpoint: cfg[:endpoint] || "not set",
      model: cfg[:model] || "not set",
      dimension: cfg[:dimension] || "not set"
    }
  end

  defp load_ingestion_config do
    cfg = Application.get_env(:zaq, :ingestion, [])

    %{
      max_context_window: cfg[:max_context_window] || 5_000,
      distance_threshold: cfg[:distance_threshold] || 0.75,
      hybrid_search_limit: cfg[:hybrid_search_limit] || 20,
      chunk_min_tokens: cfg[:chunk_min_tokens] || 400,
      chunk_max_tokens: cfg[:chunk_max_tokens] || 900
    }
  end

  defp load_prompt_templates do
    PromptTemplate.list()
  rescue
    _ -> []
  end

  defp document_count do
    Zaq.Repo.aggregate(Document, :count)
  rescue
    _ -> nil
  end

  defp chunk_count do
    Zaq.Repo.aggregate(Chunk, :count)
  rescue
    _ -> nil
  end
end
