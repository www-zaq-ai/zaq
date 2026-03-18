defmodule Zaq.Engine.StaleQuestionsCleanupWorker do
  @moduledoc """
  Oban cron worker that expires stale entries from `Zaq.Channels.PendingQuestions`.

  Scheduled to run hourly (see `:crontab` in Oban config). Questions that
  never receive an SME reply (e.g. the SME ignored the thread, or the bot
  crashed before the reply arrived) would otherwise remain in the in-memory
  Agent indefinitely, causing a memory leak and stale callback references.

  TTL is configurable via `:pending_question_ttl_seconds` app env
  (default: 86_400 seconds / 24 hours).
  """

  use Oban.Worker, queue: :knowledge_gap, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    ttl = Application.get_env(:zaq, :pending_question_ttl_seconds, 86_400)
    pending_questions_module().expire_stale(ttl)
    :ok
  end

  defp pending_questions_module do
    Application.get_env(:zaq, :pending_questions_module, Zaq.Channels.PendingQuestions)
  end
end
