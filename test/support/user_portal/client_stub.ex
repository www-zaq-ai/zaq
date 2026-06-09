defmodule Zaq.UserPortal.ClientStub do
  @moduledoc false
  # Default test-env portal client: behaves as if the portal is unreachable.
  # Used by every test that does not care about portal flows so no Mox setup
  # is required. Tests that exercise portal interaction switch to ClientMock
  # via Zaq.PortalStubs.stub_portal_reachable/0.
  @behaviour Zaq.UserPortal.ClientBehaviour

  @impl true
  def fetch_onboarding(_slug), do: :unavailable

  @impl true
  def onboard_user(_email), do: {:error, :econnrefused}

  @impl true
  def update_email(_email), do: {:error, :econnrefused}
end
