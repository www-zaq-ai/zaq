defmodule Zaq.License.ObanFeature do
  @moduledoc """
  Behaviour for licensed feature modules that require Oban resources.

  Implement this behaviour in any module that needs queues or crontab entries
  provisioned when the license is loaded into the BEAM.

  Both callbacks are required. Return `[]` from either if not needed.

  ## Example

      defmodule LicenseManager.Paid.KnowledgeGap do
        @behaviour Zaq.License.ObanFeature

        @impl true
        def oban_queues, do: [knowledge_gap: 5]

        @impl true
        def oban_crontab, do: [{"0 * * * *", Zaq.Engine.StaleQuestionsCleanupWorker}]
      end
  """

  @type queue_spec :: {atom(), pos_integer()}
  @type cron_spec :: {String.t(), module()}

  @callback oban_queues() :: [queue_spec()]
  @callback oban_crontab() :: [cron_spec()]
end
