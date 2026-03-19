defmodule Zaq.Engine.KnowledgeGapCallbackWorker do
  @moduledoc """
  Oban worker that ingests an SME answer into the knowledge base.

  Enqueued by `LicenseManager.Paid.KnowledgeGap` when a pending question
  receives a reply via the `:reply_received` hook.

  Running the resolve step as an Oban job (rather than inline in the callback)
  provides retry semantics: if the DB or ingestion pipeline is temporarily
  unavailable when the reply arrives, Oban retries up to 5 times with
  exponential backoff instead of silently dropping the answer.
  """

  use Oban.Worker,
    queue: :knowledge_gap,
    max_attempts: 5,
    unique: [period: 300, fields: [:args]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"question_id" => question_id, "answer" => answer}}) do
    table_name = Application.get_env(:zaq, :knowledge_gap_table, "chunks")

    case knowledge_gap_module().resolve(question_id, answer, table_name) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp knowledge_gap_module do
    Application.get_env(:zaq, :knowledge_gap_module, LicenseManager.Paid.KnowledgeGap)
  end
end
