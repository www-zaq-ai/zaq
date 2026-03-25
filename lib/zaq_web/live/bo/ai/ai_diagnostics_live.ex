defmodule ZaqWeb.Live.BO.AI.AIDiagnosticsLive do
  use ZaqWeb, :live_view

  alias Zaq.Agent.{LLM, PromptTemplate, Retrieval, TokenEstimator}
  alias Zaq.Embedding.Client, as: EmbeddingClient
  alias Zaq.Ingestion.{Chunk, Document}
  alias Zaq.Ingestion.Python.{Runner, Steps.ImageToText}

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/bo/ai-diagnostics",

       llm_config: load_llm_config(),
       embedding_config: load_embedding_config(),
       ingestion_config: load_ingestion_config(),
       image_to_text_config: load_image_to_text_config(),
       llm_status: :idle,
       embedding_status: :idle,
       image_to_text_status: :idle,
       pdf_pipeline_status: :idle,
       token_test_result: nil,
       prompt_templates: load_prompt_templates(),
       document_count: document_count(),
       chunk_count: chunk_count()
     )}
  end

  def handle_event("test_llm", _params, socket) do
    socket = assign(socket, llm_status: :loading)

    status =
      case Retrieval.ask("ping") do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, inspect(reason)}
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

  def handle_event("test_image_to_text", _params, socket) do
    socket = assign(socket, image_to_text_status: :loading)
    {:noreply, assign(socket, image_to_text_status: ImageToText.ping())}
  end

  def handle_event("test_token_estimator", _params, socket) do
    sample = "The quick brown fox jumps over the lazy dog"
    result = TokenEstimator.estimate(sample)
    {:noreply, assign(socket, token_test_result: result)}
  end

  def handle_event("test_pdf_pipeline", _params, socket) do
    socket = assign(socket, pdf_pipeline_status: :loading)

    status =
      try do
        scripts_dir = Runner.scripts_dir()

        if File.dir?(scripts_dir) do
          python = Runner.python_executable()

          case System.cmd(python, ["--version"], stderr_to_stdout: true) do
            {_output, 0} -> :ok
            {output, _} -> {:error, "Python unavailable: #{String.trim(output)}"}
          end
        else
          {:error, "Scripts not found. Run: mix zaq.python.fetch"}
        end
      rescue
        e -> {:error, Exception.message(e)}
      end

    {:noreply, assign(socket, pdf_pipeline_status: status)}
  end

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
    cfg = Application.get_env(:zaq, Zaq.Ingestion, [])

    %{
      max_context_window: cfg[:max_context_window] || 5_000,
      distance_threshold: cfg[:distance_threshold] || 0.75,
      hybrid_search_limit: cfg[:hybrid_search_limit] || 20,
      chunk_min_tokens: cfg[:chunk_min_tokens] || 400,
      chunk_max_tokens: cfg[:chunk_max_tokens] || 900
    }
  end

  defp load_image_to_text_config do
    cfg = Application.get_env(:zaq, Zaq.Ingestion.Python.ImageToText, [])

    %{
      api_url: cfg[:api_url] || "not set",
      model: cfg[:model] || "not set",
      api_key_set: cfg[:api_key] not in [nil, ""]
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
