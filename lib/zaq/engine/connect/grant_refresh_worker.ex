defmodule Zaq.Engine.Connect.GrantRefreshWorker do
  @moduledoc "Refreshes expiring OAuth grants proactively."

  use Oban.Worker, queue: :channels, max_attempts: 3

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Grant
  alias Zaq.Repo

  @impl Oban.Worker
  def backoff(job), do: 120 + Oban.Worker.backoff(job)

  @impl Oban.Worker
  def perform(job), do: perform(job, [])

  @doc "Refreshes a persisted grant with the runtime config/clock opts carrier."
  @spec perform(Oban.Job.t(), keyword()) :: :ok | {:error, term()}
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
      {:error, _reason} = error -> error
    end
  end

  defp perform_refresh(_, _), do: :ok
end
