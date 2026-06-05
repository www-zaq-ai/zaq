defmodule Zaq.PortalStubs do
  @moduledoc """
  Mox stubs for the portal client (`Zaq.UserPortal.ClientMock`).

  Call `stub_portal_reachable/0` in a setup block for any test that mounts
  DashboardLive or ChangePasswordLive, which render portal metadata through the
  consent modal. The LiveView process inherits the stub via Mox's `$callers`
  ownership chain.
  """

  @valid_onboarding_response %{
    "status" => "ok",
    "message" => %{
      "message" => "Free credits activated — your ZAQ portal account is ready.",
      "offer_slug" => "free",
      "metadata" => %{
        "title" => "Activate your free credits",
        "body" => "To create your ZAQ account...",
        "accept_label" => "Accept & activate free credits",
        "decline_label" => "Decline — continue without free credits",
        "subtitle" => "Optional · You can skip this",
        "footnote" => "Free credits can be claimed later from the dashboard.",
        "banner_text" => "Claim your $2 in free AI credits — activate your ZAQ portal account."
      }
    }
  }

  @doc "Full portal onboarding response body (status + message)."
  def onboarding_response, do: @valid_onboarding_response

  @doc "The inner `message` map, matching what `Client.fetch_onboarding/1` returns."
  def onboarding_message, do: @valid_onboarding_response["message"]

  def stub_portal_reachable do
    Mox.stub(Zaq.UserPortal.ClientMock, :fetch_onboarding, fn _slug ->
      {:ok, onboarding_message()}
    end)

    Mox.stub(Zaq.UserPortal.ClientMock, :onboard_user, fn _email ->
      {:ok, %{litellm_api_key: "sk-test-key"}}
    end)
  end

  def stub_portal_unreachable do
    Mox.stub(Zaq.UserPortal.ClientMock, :fetch_onboarding, fn _slug -> :unavailable end)

    Mox.stub(Zaq.UserPortal.ClientMock, :onboard_user, fn _email ->
      {:error, :econnrefused}
    end)
  end

  @doc """
  Portal is reachable, but `onboard_user/1` responds with the given non-200
  `status` and `body` (matching `Client.onboard_user/1`'s `{:error, {status, body}}`
  shape). Use to exercise error messaging such as a 409 "user already exists".
  """
  def stub_portal_onboard_error(status, body) do
    Mox.stub(Zaq.UserPortal.ClientMock, :fetch_onboarding, fn _slug ->
      {:ok, onboarding_message()}
    end)

    Mox.stub(Zaq.UserPortal.ClientMock, :onboard_user, fn _email ->
      {:error, {status, body}}
    end)
  end
end
