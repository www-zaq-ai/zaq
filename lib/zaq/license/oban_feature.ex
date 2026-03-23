defmodule Zaq.License.ObanFeature do
  @moduledoc """
  Behaviour for licensed feature modules that require Oban resources.

  Implement this behaviour in any module that needs queues or crontab entries
  provisioned when the license is loaded into the BEAM.

  All three callbacks are required. Return `[]` from `oban_queues/0` or `oban_crontab/0`
  if not needed.

  `feature_key/0` returns a unique atom identifying this feature. It is used as the
  idempotency key by `Zaq.Oban.DynamicCron` — if the license is reloaded, schedules
  for an already-registered key are not re-added.

  ## Example

      defmodule LicenseManager.Paid.KnowledgeGap do
        @behaviour Zaq.License.ObanFeature

        @impl true
        def feature_key, do: :knowledge_gap

        @impl true
        def oban_queues, do: [knowledge_gap: 5]

        @impl true
        def oban_crontab, do: [{"0 * * * *", Zaq.Engine.StaleQuestionsCleanupWorker}]
      end
  """

  @type queue_spec :: {atom(), pos_integer()}
  @type cron_spec :: {String.t(), module()}

  @callback feature_key() :: atom()
  @callback oban_queues() :: [queue_spec()]
  @callback oban_crontab() :: [cron_spec()]
end
