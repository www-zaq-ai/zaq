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
  Maps a provisioning error to `{user_message, mode}`.

  `mode` is `:allow_override` for an email conflict (409 — the caller should
  reveal the email-correction input) or `:none` for a generic error (show the
  message only). Shared by both consent flows so the 409 wording stays in sync.
  """
  @spec provision_error(term()) :: {String.t(), :allow_override | :none}
  def provision_error({409, body}) do
    msg =
      case body do
        %{"message" => m} when is_binary(m) and m != "" -> m
        _ -> "This email is already registered with ZAQ Portal."
      end

    {msg <> " Please use a different email address.", :allow_override}
  end

  def provision_error({_status, %{"message" => message}})
      when is_binary(message) and message != "" do
    {message, :none}
  end

  def provision_error(_reason),
    do: {"Could not reach the ZAQ portal. Please try again later.", :none}
end
