defmodule Zaq.Engine.Connect.GrantRefreshWorker do
  @moduledoc "Refreshes expiring OAuth grants proactively."

  use Oban.Worker, queue: :channels, max_attempts: 3

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Grant
  alias Zaq.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"grant_id" => grant_id}}) do
    case Repo.get(Grant, grant_id) do
      nil -> :ok
      %Grant{} = grant -> perform_refresh(grant)
    end
  end

  defp perform_refresh(%Grant{status: "active", auth_kind: "oauth2"} = grant) do
    case Connect.refresh_grant(grant) do
      {:ok, _grant} -> :ok
      {:error, :unsupported} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp perform_refresh(_), do: :ok
end
