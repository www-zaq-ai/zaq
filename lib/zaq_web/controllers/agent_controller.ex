defmodule ZaqWeb.AgentController do
  use ZaqWeb, :controller

  require Logger

  alias Zaq.Engine.Telemetry
  alias Zaq.NodeRouter
  alias Zaq.RuntimeDeps
  alias ZaqWeb.APIResponse

  @doc """
  POST /api/ask
  Body: {"content": "...", "history": %{}}
  """
  def ask(conn, %{"content" => content} = params) do
    prompt_guard = prompt_guard_module()
    retrieval = retrieval_module()
    document_processor = document_processor_module()
    answering = answering_module()

    history = Map.get(params, "history", %{})
    telemetry_dimensions = %{channel_type: "api", channel_config_id: "unknown"}

    with {:ok, clean_msg} <- prompt_guard.validate(content),
         :ok <- record_metric("qa.message.count", 1, telemetry_dimensions),
         {:ok, %{"query" => query, "language" => lang}} <-
           retrieval.ask(clean_msg, history: history),
         {:ok, [%{"total_count" => count}]} <-
           document_processor.similarity_search_count(query),
         true <- count > 0,
         {:ok, query_results} <- document_processor.query_extraction(query),
         {:ok, raw_result} <- answering.ask(query_results, history: history),
         {:ok, result} <- normalize_answer_result(answering, raw_result),
         answer when is_binary(answer) <- result.answer,
         score <- result.confidence_score || 0.0,
         {:ok, safe_answer} <- prompt_guard.output_safe?(answer) do
      if answering.no_answer?(safe_answer) do
        :ok = record_metric("qa.no_answer.count", 1, telemetry_dimensions)

        APIResponse.ok(conn, %{
          answer: answering.clean_answer(safe_answer),
          confidence: 0,
          language: lang
        })
      else
        APIResponse.ok(conn, %{answer: safe_answer, confidence: score, language: lang})
      end
    else
      false ->
        :ok = record_metric("qa.no_answer.count", 1, telemetry_dimensions)
        APIResponse.ok(conn, %{answer: "No relevant information found.", confidence: 0})

      {:error, {:leaked, _phrase}} ->
        APIResponse.error(conn, :forbidden, "blocked")

      {:error, reason} ->
        Logger.error("AgentController.ask failed: #{inspect(reason)}")
        APIResponse.error(conn, :internal_server_error, "internal_error")
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
        APIResponse.accepted(conn, %{status: "accepted", result: data})

      {:error, reason} ->
        Logger.error("AgentController.ingest failed: #{inspect(reason)}")
        APIResponse.error(conn, :unprocessable_entity, inspect(reason))
    end
  end

  defp prompt_guard_module do
    RuntimeDeps.prompt_guard()
  end

  defp retrieval_module do
    RuntimeDeps.retrieval()
  end

  defp document_processor_module do
    RuntimeDeps.document_processor()
  end

  defp answering_module do
    RuntimeDeps.answering()
  end

  defp normalize_answer_result(module, result) do
    if function_exported?(module, :normalize_result, 1) do
      module.normalize_result(result)
    else
      case result do
        %{answer: answer} when is_binary(answer) -> {:ok, result}
        _ -> {:error, :invalid_result}
      end
    end
  end

  defp record_metric(metric_key, value, dimensions) do
    _ = NodeRouter.call(:engine, Telemetry, :record, [metric_key, value, dimensions])
    :ok
  rescue
    _ -> :ok
  end
end
