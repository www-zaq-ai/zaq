defmodule Zaq.UserPortal do
  @moduledoc """
  Entry point for the User Portal boundary.

  Holds shared configuration accessors used across the UserPortal modules
  (`Client`, `Provisioner`, `AccountSync`, `Onboarding`) and the BO LiveViews
  that drive portal consent. Keeping the configurable client lookup here avoids
  the same `Application.get_env/3` call being copy-pasted into every module.
  """

  @doc """
  Returns the configured portal client module.

  Defaults to `Zaq.UserPortal.Client`; tests override it with a `Mox` mock via
  `Application.put_env(:zaq, :user_portal_client, ...)`.
  """
  @spec client() :: module()
  def client, do: Application.get_env(:zaq, :user_portal_client, Zaq.UserPortal.Client)

  @doc "Returns the configured user-portal base URL (e.g. for building links)."
  @spec base_url() :: String.t()
  def base_url, do: Application.fetch_env!(:zaq, :user_portal_base_url)

  @doc """
  True when the portal payload reports the plan as enabled.

  Reads the `"plan_status"` field of the onboarding payload. Shared by the
  bootstrap (`ChangePasswordLive`) and dashboard-retry (`PortalConsentLive`)
  consent flows so the metadata format lives in one place.
  """
  @spec plan_enabled?(map() | nil) :: boolean()
  def plan_enabled?(%{"plan_status" => "enabled"}), do: true
  def plan_enabled?(_), do: false

  @doc """
  True when the portal payload reports the plan as available.

  Reads the `"available"` field of the onboarding payload.
  """
  @spec plan_available?(map() | nil) :: boolean()
  def plan_available?(nil), do: false
  def plan_available?(metadata), do: Map.get(metadata, "available", false) == true

  @doc """
  True when the plan is both enabled and available — the gate for offering the
  portal consent modal/banner.
  """
  @spec plan_active?(map() | nil) :: boolean()
  def plan_active?(payload), do: plan_enabled?(payload) and plan_available?(payload)

  @doc """
  Maps a provisioning error to a user-facing message.

  A 409 means the email already exists on the portal, so re-provisioning cannot
  help — the user must fetch the existing key and set it on the ZAQ Router
  credential, which the message states. Other portal errors surface the portal's
  own message; transport failures fall back to a generic message.
  """
  @spec provision_error(term()) :: String.t()
  def provision_error({409, _body}),
    do:
      "Your email is already registered in the user portal — get your key and set it in the ZAQ Router credential."

  def provision_error({_status, %{"message" => message}})
      when is_binary(message) and message != "",
      do: message

  def provision_error(_reason),
    do: "Could not reach the ZAQ portal. Please try again later."
end
