defmodule Zaq.Engine.Connect.GrantRefreshWorker do
  @moduledoc """
  Refreshes OAuth grants through the shared claimed-refresh boundary.

  Pending jobs are unique per grant. If runtime use already owns the grant's DB lease,
  the job snoozes until that lease expires instead of recording expected contention as
  a failed attempt.
  """

  use Oban.Worker,
    queue: :channels,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Grant
  alias Zaq.Repo
  alias Zaq.Utils.DateUtils

  @impl Oban.Worker
  def backoff(job), do: 120 + Oban.Worker.backoff(job)

  @impl Oban.Worker
  def perform(job), do: perform(job, [])

  @doc "Refreshes a persisted grant with the runtime config/clock opts carrier."
  @spec perform(Oban.Job.t(), keyword()) :: :ok | {:error, term()} | {:snooze, pos_integer()}
  def perform(%Oban.Job{args: %{"grant_id" => grant_id}}, opts) do
    case Repo.get(Grant, grant_id) do
      nil -> :ok
      %Grant{} = grant -> perform_refresh(grant, opts)
    end
  end

  defp perform_refresh(%Grant{status: status, auth_kind: "oauth2"} = grant, opts)
       when status in ["active", "expired"] do
    case Connect.refresh_grant(grant, opts) do
      {:ok, _grant} -> :ok
      {:error, :unsupported} -> :ok
      {:error, :refresh_busy} -> snooze_until_lease_expires(grant.id, opts)
      {:error, _reason} = error -> error
    end
  end

  defp perform_refresh(_, _), do: :ok

  defp snooze_until_lease_expires(grant_id, opts) do
    now = opts |> DateUtils.now() |> DateTime.truncate(:second)

    case Repo.get(Grant, grant_id) do
      %Grant{refresh_claim_until: %DateTime{} = deadline} ->
        {:snooze, max(DateTime.diff(deadline, now, :second), 1)}

      _ ->
        {:snooze, 1}
    end
  end
end
