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
    history = Map.get(params, "history", %{})

    with {:ok, clean_msg} <- PromptGuard.validate(question),
         {:ok, %{"query" => query, "language" => lang}} <-
           Retrieval.ask(clean_msg, history: history),
         {:ok, [%{"total_count" => count}]} <-
           DocumentProcessor.similarity_search_count(query),
         true <- count > 0,
         {:ok, query_results} <- DocumentProcessor.query_extraction(query),
         {:ok, %{answer: answer, confidence: %{score: score}}} <-
           Answering.ask(query_results, history: history),
         {:ok, safe_answer} <- PromptGuard.output_safe?(answer) do
      if Answering.no_answer?(safe_answer) do
        json(conn, %{
          answer: Answering.clean_answer(safe_answer),
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
    result =
      if File.dir?(path),
        do: DocumentProcessor.process_folder(path),
        else: DocumentProcessor.process_single_file(path)

    case result do
      {:ok, data} ->
        conn |> put_status(202) |> json(%{status: "accepted", result: data})

      {:error, reason} ->
        Logger.error("AgentController.ingest failed: #{inspect(reason)}")
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end
end
