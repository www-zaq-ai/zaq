defmodule Zaq.UserPortal.ClientBehaviour do
  @moduledoc """
  Behaviour for the Zaq User Portal HTTP client.

  Production code resolves the implementation through
  `Application.get_env(:zaq, :user_portal_client, Zaq.UserPortal.Client)`, which
  lets tests substitute a `Mox` mock instead of stubbing HTTP plumbing.
  """

  @callback onboard_user(email :: String.t()) ::
              {:ok, %{litellm_api_key: String.t()}} | {:error, term()}

  @callback fetch_onboarding(slug :: String.t()) :: {:ok, map()} | :unavailable

  @callback update_email(email :: String.t(), api_key :: String.t() | nil) ::
              :ok | {:error, term()}
end
