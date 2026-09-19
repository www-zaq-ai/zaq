defmodule Zaq.Engine.Connect.MutationEventWorker do
  @moduledoc """
  Delivers a committed Connect mutation notification to the Agent role.

  Uses Connect's three-attempt convention and Oban's default exponential jittered backoff.
  Errors contain only fixed atoms; Oban never receives provider response bodies or
  exception messages. Exhausted jobs require explicit later operational replay.
  """

  use Oban.Worker, queue: :connect_credential_notifications, max_attempts: 3

  alias Zaq.Engine.Connect.MutationEvents

  @impl Oban.Worker
  def perform(%Oban.Job{args: payload}), do: MutationEvents.deliver(payload)
end
