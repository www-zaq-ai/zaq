defmodule Zaq.UserPortal.AccountSync do
  @moduledoc """
  Syncs account changes for consented users to the User Portal.

  Only users with `portal_consent: "accepted"` are synced. Portal failures
  are logged but never block the local DB operation — the portal is best-effort.
  """

  alias Zaq.Accounts.User
  alias Zaq.System
  alias Zaq.UserPortal.Provisioner

  require Logger

  @doc """
  Syncs the user's current email to the portal.

  Returns `:ok` on success or if the user has not accepted portal consent.
  Returns `{:error, reason}` when the portal rejects the update.
  """
  @spec sync_email(User.t()) :: :ok | {:error, term()}
  def sync_email(%User{portal_consent: "accepted", email: email}) when is_binary(email) do
    case Zaq.UserPortal.client().update_email(email, zaq_router_api_key()) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Portal email sync failed for #{email}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def sync_email(%User{}), do: :ok

  defp zaq_router_api_key do
    case System.get_ai_provider_credential_by_name(Provisioner.credential_name()) do
      %{api_key: key} when is_binary(key) -> key
      _ -> nil
    end
  end
end
