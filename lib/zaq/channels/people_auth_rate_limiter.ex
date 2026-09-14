defmodule Zaq.Channels.PeopleAuthRateLimiter do
  @moduledoc """
  Channels-owned unsuccessful-identification IP budget.

  Precheck locally before a future authentication Engine dispatch. Only an unknown
  or ineligible outcome from that same request should record a failure. Successful
  identification consumes nothing here; Engine owns all OTP issuance budgets and
  persisted verification attempts. There is no broad ingress ceiling.

  These APIs do not implement the public login flow or dispatch authentication.
  They use only the background-refreshed typed config and local Hammer counters.
  Every error must prevent dispatch. IPs must be trusted IPv4/IPv6 address tuples.
  """
  use Supervisor

  alias Zaq.Channels.PeopleAuthRateLimiter.Config
  alias Zaq.People.AuthRateLimiter

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([{AuthRateLimiter, role: :channels}, Config], strategy: :one_for_one)
  end

  @doc "Non-consuming local precheck; any error must deny the future Engine request."
  @spec check_identification(term()) :: :ok | {:error, term()}
  def check_identification(ip) do
    with :ok <- AuthRateLimiter.validate_ip(ip),
         {:ok, config} <- Config.get() do
      AuthRateLimiter.check(
        :channels,
        {:identification, ip},
        config.unknown_email_window_seconds * 1_000,
        config.unknown_email_attempt_limit
      )
    end
  end

  @doc "Record once for an unknown/ineligible response; never for an eligible identification."
  @spec record_failed_identification(term()) :: :ok | {:error, term()}
  def record_failed_identification(ip) do
    with :ok <- AuthRateLimiter.validate_ip(ip),
         {:ok, config} <- Config.get() do
      AuthRateLimiter.hit(
        :channels,
        {:identification, ip},
        config.unknown_email_window_seconds * 1_000,
        config.unknown_email_attempt_limit
      )
    end
  end
end
