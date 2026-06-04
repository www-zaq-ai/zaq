defmodule Zaq.PortalStubs do
  @moduledoc """
  Req.Test stubs for Zaq.UserPortal.Client.

  Call `stub_portal_reachable/0` in a setup block for any test that mounts
  DashboardLive or ChangePasswordLive, which call PortalClient.fetch_onboarding/1
  at mount time.
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

  def onboarding_response, do: @valid_onboarding_response

  def stub_portal_reachable do
    Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/health/liveliness"} ->
          Req.Test.json(conn, "I'm alive!")

        {"GET", "/onboarding/" <> _slug} ->
          Req.Test.json(conn, @valid_onboarding_response)

        {"POST", "/onboarding"} ->
          Req.Test.json(conn, %{
            "status" => "ok",
            "user" => %{
              "litellm_api_key" => "sk-test-key",
              "litellm_user_id" => "llm-user-test"
            }
          })
      end
    end)
  end

  def stub_portal_unreachable do
    Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)
  end
end
