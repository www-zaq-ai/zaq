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
end
