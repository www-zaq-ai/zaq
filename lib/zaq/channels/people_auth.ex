defmodule Zaq.Channels.PeopleAuth do
  @moduledoc """
  Channels-local public login ingress. Failed identification protection is checked
  before the single Engine request, without request-time configuration reads.
  Only Engine's unknown/ineligible result spends the local failure budget.
  """
  alias Zaq.Channels.PeopleAuthRateLimiter
  alias Zaq.Engine.Events

  @spec request_challenge(term(), term()) :: {:ok, map()} | {:error, term()}
  def request_challenge(email, ip) do
    with :ok <- PeopleAuthRateLimiter.check_identification(ip) do
      result =
        Events.build_and_dispatch_invoke_event(
          %{op: :request_challenge, email: email, ip: ip},
          :people_auth,
          event_opts: [confidential: true]
        ).response

      if result == {:error, :failed_identification} do
        PeopleAuthRateLimiter.record_failed_identification(ip)
      end

      result
    end
  end
end
