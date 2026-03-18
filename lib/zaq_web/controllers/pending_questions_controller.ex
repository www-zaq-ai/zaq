defmodule ZaqWeb.PendingQuestionsController do
  use ZaqWeb, :controller

  alias Zaq.Engine.Router
  alias Zaq.License.FeatureStore

  require Logger

  @doc """
  Receives a pending question and dispatches it through the Engine Router
  to the appropriate retrieval channel adapter.
  Gated by the knowledge_gap license check.

  Expected payload:
    {
      "question_id": 42,
      "question": "How do I renew my medical license in Dubai?",
      "language": "en",
      "source_type": "chat_widget",
      "channel_id": "<retrieval_channel_id>"
    }
  """
  def create(conn, params) do
    with :ok <- check_license(),
         {:ok, attrs} <- validate_params(params) do
      formatted = format_question(attrs)
      callback = build_callback(attrs.question_id)

      case engine_router_module().dispatch_question(attrs.channel_id, formatted, callback) do
        {:ok, post_id} ->
          Logger.info("Posted question #{attrs.question_id} to channel (post: #{post_id})")

          conn
          |> put_status(:ok)
          |> json(%{status: "ok", post_id: post_id})

        {:error, reason} ->
          Logger.error("Failed to post question #{attrs.question_id}: #{inspect(reason)}")

          conn
          |> put_status(:bad_gateway)
          |> json(%{error: "failed_to_post", detail: inspect(reason)})
      end
    else
      {:error, :feature_not_licensed} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "feature_not_licensed", feature: "knowledge_gap"})

      {:error, missing} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "missing_fields", fields: missing})
    end
  end

  # --- Private ---

  defp check_license do
    if feature_store_module().feature_loaded?("knowledge_gap") do
      :ok
    else
      {:error, :feature_not_licensed}
    end
  end

  @required_fields ~w(question_id question channel_id)

  defp validate_params(params) do
    missing = Enum.filter(@required_fields, &(not Map.has_key?(params, &1)))

    if missing == [] do
      {:ok,
       %{
         question_id: params["question_id"],
         question: params["question"],
         language: params["language"] || "en",
         source_type: params["source_type"] || "unknown",
         channel_id: params["channel_id"]
       }}
    else
      {:error, missing}
    end
  end

  defp format_question(attrs) do
    """
    #{attrs.question}

    Reply to this thread with the answer.\
    """
  end

  defp build_callback(question_id) do
    knowledge_gap = knowledge_gap_module()

    fn answer ->
      table_name = Application.get_env(:zaq, :knowledge_gap_table, "chunks")

      case knowledge_gap.resolve(question_id, answer, table_name) do
        {:ok, _} ->
          Logger.info("Resolved question #{question_id} via in-process callback")
          :ok

        {:error, reason} ->
          Logger.error("Failed to resolve question #{question_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp engine_router_module do
    Application.get_env(:zaq, :engine_router_module, Router)
  end

  defp feature_store_module do
    Application.get_env(:zaq, :feature_store_module, FeatureStore)
  end

  defp knowledge_gap_module do
    Application.get_env(:zaq, :knowledge_gap_module, LicenseManager.Paid.KnowledgeGap)
  end
end
