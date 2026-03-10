defmodule ZaqWeb.PendingQuestionsController do
  use ZaqWeb, :controller

  alias Zaq.Channels.PendingQuestions
  alias Zaq.Channels.Retrieval.Mattermost.API, as: MattermostAPI
  alias Zaq.License.FeatureStore

  require Logger
  # credo:disable-for-this-file Credo.Check.Refactor.Apply

  @doc """
  Receives a pending question and posts it to the appropriate channel.
  Gated by the knowledge_gap license check.

  Expected payload:
    {
      "question_id": 42,
      "question": "How do I renew my medical license in Dubai?",
      "language": "en",
      "source_type": "chat_widget",
      "channel_id": "<sme_channel_id>"
    }
  """
  def create(conn, params) do
    pending_questions = pending_questions_module()
    mattermost_api = mattermost_api_module()

    with :ok <- check_license(),
         {:ok, attrs} <- validate_params(params) do
      formatted = format_question(attrs)

      callback = build_callback(attrs.question_id)

      case pending_questions.ask(
             attrs.channel_id,
             "zaq_agent",
             formatted,
             &mattermost_api.send_message(&1, &2, nil),
             callback
           ) do
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

  defp pending_questions_module do
    Application.get_env(:zaq, :pending_questions_module, PendingQuestions)
  end

  defp mattermost_api_module do
    Application.get_env(:zaq, :mattermost_api_module, MattermostAPI)
  end

  defp feature_store_module do
    Application.get_env(:zaq, :feature_store_module, FeatureStore)
  end

  defp knowledge_gap_module do
    Application.get_env(:zaq, :knowledge_gap_module, LicenseManager.Paid.KnowledgeGap)
  end
end
