defmodule ZaqWeb.AgentController do
  use ZaqWeb, :controller

  require Logger

  alias Zaq.Agent.{Answering, PromptGuard, Retrieval}
  alias Zaq.Ingestion.DocumentProcessor

  @doc """
  POST /api/ask
  Body: {"question": "...", "history": %{}}
  """
  def ask(conn, %{"question" => question} = params) do
    prompt_guard = prompt_guard_module()
    retrieval = retrieval_module()
    document_processor = document_processor_module()
    answering = answering_module()

    history = Map.get(params, "history", %{})

    with {:ok, clean_msg} <- prompt_guard.validate(question),
         {:ok, %{"query" => query, "language" => lang}} <-
           retrieval.ask(clean_msg, history: history),
         {:ok, [%{"total_count" => count}]} <-
           document_processor.similarity_search_count(query),
         true <- count > 0,
         {:ok, query_results} <- document_processor.query_extraction(query),
         {:ok, %{answer: answer, confidence: %{score: score}}} <-
           answering.ask(query_results, history: history),
         {:ok, safe_answer} <- prompt_guard.output_safe?(answer) do
      if answering.no_answer?(safe_answer) do
        json(conn, %{
          answer: answering.clean_answer(safe_answer),
          confidence: 0,
          language: lang
        })
      else
        json(conn, %{answer: safe_answer, confidence: score, language: lang})
      end
    else
      false ->
        json(conn, %{answer: "No relevant information found.", confidence: 0})

      {:error, {:leaked, _phrase}} ->
        conn |> put_status(403) |> json(%{error: "blocked"})

      {:error, reason} ->
        Logger.error("AgentController.ask failed: #{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: "internal_error"})
    end
  end

  @doc """
  POST /api/ingest
  Body: {"path": "/path/to/file_or_folder"}
  """
  def ingest(conn, %{"path" => path}) do
    document_processor = document_processor_module()

    result =
      if File.dir?(path),
        do: document_processor.process_folder(path),
        else: document_processor.process_single_file(path, nil)

    case result do
      {:ok, data} ->
        conn |> put_status(202) |> json(%{status: "accepted", result: data})

      {:error, reason} ->
        Logger.error("AgentController.ingest failed: #{inspect(reason)}")
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  defp prompt_guard_module do
    Application.get_env(:zaq, :agent_prompt_guard_module, PromptGuard)
  end

  defp retrieval_module do
    Application.get_env(:zaq, :agent_retrieval_module, Retrieval)
  end

  defp document_processor_module do
    Application.get_env(:zaq, :agent_document_processor_module, DocumentProcessor)
  end

  defp answering_module do
    Application.get_env(:zaq, :agent_answering_module, Answering)
  end
end
