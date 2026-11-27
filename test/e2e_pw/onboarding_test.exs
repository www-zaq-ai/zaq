defmodule Zaq.E2EPw.OnboardingTest do
  @moduledoc """
  Onboarding E2E: covers all critical scenarios end to end.

  Bootstrap scenarios (1-3, 7, 8): user lands on /bo/change-password, sets email + password,
  then makes a portal consent decision. State is seeded via the E2E API; the portal loopback
  stub at /e2e/portal/* handles all portal calls.

  Dashboard retry scenarios (4, 5, 9): user has already completed bootstrap with
  portal_consent="declined" and is retrying from the dashboard banner.
  """

  # Split into one module per describe, as the specs' two describes.
  defmodule Shared do
    @moduledoc false
    alias Playwright.{APIRequest, Expect, Locator, Page}
    alias Playwright.Test.BrowserPool
    import Zaq.E2EPw.BO
    import Playwright.Test.Assertions

    def strong_password, do: "StrongPass1!"
    def onboard_email, do: "fresh.admin@e2e.local"
    def conflict_email, do: "already-taken@e2e.local"
    def corrected_email, do: "corrected.admin@e2e.local"

    def sel(:email), do: "#email"
    def sel(:password), do: "#password"
    def sel(:password_confirmation), do: "#password-confirmation"
    def sel(:accept_consent), do: ~s|[phx-click="accept_portal_consent"]|
    def sel(:decline_consent), do: ~s|[phx-click="decline_portal_consent"]|
    def sel(:modal_email_input), do: "#portal-consent-email"
    def sel(:got_it_button), do: ~s|button:has-text("Got it")|
    def sel(:activate_button), do: ~s|button:has-text("Activate")|
    def sel(:user_email_input), do: ~s|input[name="user[email]"]|
    def sel(:save_changes), do: ~s|button:has-text("Save Changes")|

    # Assert all three post-accept modal fields are visible.
    def verify_post_accept_modal(page) do
      page |> Page.get_by_text("Activation email has been sent") |> Expect.to_be_visible!()

      page
      |> Page.get_by_text("Verify your email within 4 hours to keep using your free credits")
      |> Expect.to_be_visible!()

      page
      |> Page.get_by_text("You have the option to change your email address in your user account")
      |> Expect.to_be_visible!()
    end

    # Verify ZAQ Router credential state via the E2E API.
    def verify_zaq_router(req, has_api_key) do
      data = get_e2e_zaq_router_credential(req)
      assert(data["found"] == true)
      assert(data["has_api_key"] == has_api_key)
    end

    def new_request(browser) do
      APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))
    end

    def locator(page, key), do: Page.locator(page, sel(key))
    def click(page, key), do: page |> locator(key) |> Locator.click!()
  end
end

defmodule Zaq.E2EPw.OnboardingBootstrapTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  alias Zaq.E2EPw.OnboardingTest.Shared

  # Bootstrap onboarding
  setup %{browser: browser} do
    req = Shared.new_request(browser)
    reset_e2e_state(req)
    on_exit(fn -> APIRequestContext.dispose(req) end)
    %{req: req}
  end

  defp setup_bootstrap_user(page, req) do
    create_e2e_bootstrap_admin(req)
    Page.goto!(page, "/bo/bootstrap-login")
    Expect.to_have_url!(page, ~r{/bo/change-password}, timeout: 10_000)
    wait_for_live_view_connected(page)
  end

  defp fill_bootstrap_form(page) do
    # Filling fields one-by-one moves focus between them, triggering blur events that flush
    # phx-debounce="300" with partial state. So: fill, then restore all three values atomically
    # via the native DOM setter and submit via requestSubmit() in a single evaluate call.
    page |> Shared.locator(:email) |> Locator.fill!(Shared.onboard_email())
    page |> Shared.locator(:password) |> Locator.fill!(Shared.strong_password())
    page |> Shared.locator(:password_confirmation) |> Locator.fill!(Shared.strong_password())
    page |> Shared.locator(:password_confirmation) |> Locator.blur!()
    wait_for_live_view_settled(page)

    Page.evaluate!(
      page,
      """
      ([emailVal, pwVal, emailSel, pwSel, confirmSel]) => {
        const nativeSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set
        function fill(sel, val) {
          const el = document.querySelector(sel)
          if (el) nativeSetter.call(el, val)
        }
        fill(emailSel, emailVal)
        fill(pwSel, pwVal)
        fill(confirmSel, pwVal)
        document.querySelector("#change-password-form").requestSubmit()
      }
      """,
      [
        Shared.onboard_email(),
        Shared.strong_password(),
        Shared.sel(:email),
        Shared.sel(:password),
        Shared.sel(:password_confirmation)
      ]
    )

    wait_for_live_view_settled(page)
  end

  test "Scenario 1 — portal unreachable: skips modal, shows offline notice on dashboard", %{
    page: page,
    req: req
  } do
    # Make the portal stub return 503: the client treats it as :unavailable.
    set_e2e_portal_offline(req, true)
    setup_bootstrap_user(page, req)

    # Submit form: no modal will appear (portal_reachable: false at mount).
    expect_flash_during_action(page, "Password changed successfully", fn ->
      fill_bootstrap_form(page)
    end)

    # Redirects directly to dashboard with the standard flash.
    Expect.to_have_url!(page, ~r{/bo/dashboard}, timeout: 10_000)
    wait_for_live_view_connected(page)

    page
    |> Page.get_by_text("ZAQ portal is not reachable in this environment")
    |> Expect.to_be_visible!()

    page |> Shared.locator(:activate_button) |> Expect.to_have_count!(0)
  end

  test "Scenario 2 — accept at bootstrap: post-accept modal shown, Got it redirects to ingestion",
       %{
         page: page,
         req: req
       } do
    setup_bootstrap_user(page, req)
    fill_bootstrap_form(page)

    # Modal appears: accept the offer.
    page |> Shared.locator(:accept_consent) |> Expect.to_be_visible!()
    page |> Page.get_by_text("Activate your free credits") |> Expect.to_be_visible!()
    Shared.click(page, :accept_consent)
    wait_for_live_view_settled(page)

    # Post-accept modal appears before the redirect.
    Shared.verify_post_accept_modal(page)

    # Got it -> flash + navigate to ingestion.
    Shared.click(page, :got_it_button)
    Expect.to_have_url!(page, ~r{/bo/ingestion}, timeout: 10_000)
    wait_for_live_view_connected(page)

    page
    |> Page.get_by_text("drop your files to bring your company brain to life")
    |> Expect.to_be_visible!()

    # Dashboard must not show the retry banner.
    Page.goto!(page, "/bo/dashboard")
    wait_for_live_view_connected(page)
    page |> Shared.locator(:activate_button) |> Expect.to_have_count!(0)
    page |> Page.get_by_text("Activate your free credits") |> Expect.to_have_count!(0)

    # ZAQ Router credential must be present with an API key.
    Shared.verify_zaq_router(req, true)
  end

  test "Scenario 7 — accept at bootstrap: ZAQ Router credential present with API key", %{
    page: page,
    req: req
  } do
    setup_bootstrap_user(page, req)
    fill_bootstrap_form(page)

    page |> Shared.locator(:accept_consent) |> Expect.to_be_visible!()
    Shared.click(page, :accept_consent)
    wait_for_live_view_settled(page)

    Shared.verify_post_accept_modal(page)
    Shared.click(page, :got_it_button)
    Expect.to_have_url!(page, ~r{/bo/ingestion}, timeout: 10_000)

    Shared.verify_zaq_router(req, true)
  end

  test "Scenario 8 — decline at bootstrap: ZAQ Router credential present in system config (keyless)",
       %{
         page: page,
         req: req
       } do
    setup_bootstrap_user(page, req)
    fill_bootstrap_form(page)

    page |> Shared.locator(:decline_consent) |> Expect.to_be_visible!()
    Shared.click(page, :decline_consent)
    Expect.to_have_url!(page, ~r{/bo/dashboard}, timeout: 10_000)
    wait_for_live_view_connected(page)

    # ZAQ Router must be scaffolded even though the user declined, but keyless.
    Shared.verify_zaq_router(req, false)
  end

  test "Scenario 3 — decline at bootstrap, retry from dashboard: provisions on second accept", %{
    page: page,
    req: req
  } do
    setup_bootstrap_user(page, req)
    fill_bootstrap_form(page)

    page |> Shared.locator(:decline_consent) |> Expect.to_be_visible!()
    Shared.click(page, :decline_consent)

    # Decline -> dashboard with retry banner.
    Expect.to_have_url!(page, ~r{/bo/dashboard}, timeout: 10_000)
    wait_for_live_view_connected(page)
    page |> Shared.locator(:activate_button) |> Expect.to_be_visible!()
    page |> Page.get_by_text("Claim your $2 in free AI credits") |> Expect.to_be_visible!()

    # Open the retry modal and accept.
    Shared.click(page, :activate_button)
    page |> Shared.locator(:accept_consent) |> Expect.to_be_visible!()
    Shared.click(page, :accept_consent)
    wait_for_live_view_settled(page)

    Shared.verify_post_accept_modal(page)
    Shared.click(page, :got_it_button)
    wait_for_live_view_settled(page)

    # Banner disappears: consent accepted, credential provisioned.
    page |> Shared.locator(:activate_button) |> Expect.to_have_count!(0)
    page |> Page.get_by_text("Activate your free credits") |> Expect.to_have_count!(0)

    Shared.verify_zaq_router(req, true)
  end
end

defmodule Zaq.E2EPw.OnboardingDashboardRetryTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  alias Zaq.E2EPw.OnboardingTest.Shared

  # Dashboard retry
  setup %{browser: browser} do
    req = Shared.new_request(browser)
    reset_e2e_state(req)
    on_exit(fn -> APIRequestContext.dispose(req) end)
    %{req: req}
  end

  test "Scenario 4 — email conflict at retry: surfaces 409, admin corrects email, retry succeeds",
       %{
         page: page,
         req: req
       } do
    # Seed a declined user whose email is already registered in the portal.
    user = create_e2e_declined_portal_user(req, %{email: Shared.conflict_email()})
    register_e2e_portal_conflict(req, %{email: Shared.conflict_email()})

    login_to_back_office(page, username: user["username"], password: user["password"])
    Expect.to_have_url!(page, ~r{/bo/dashboard})
    wait_for_live_view_connected(page)

    # First accept attempt -> 409 error.
    Shared.click(page, :activate_button)
    page |> Shared.locator(:accept_consent) |> Expect.to_be_visible!()
    Shared.click(page, :accept_consent)
    wait_for_live_view_settled(page)

    # A 409 shows fixed guidance to set the existing key on the ZAQ Router credential.
    page |> Page.get_by_text("already registered in the user portal") |> Expect.to_be_visible!()
    # Consent unchanged: modal stays open with error.
    page |> Shared.locator(:accept_consent) |> Expect.to_be_visible!()

    # Admin corrects the email via the user edit form.
    Page.goto!(page, "/bo/users/#{user["user_id"]}/edit")
    wait_for_live_view_connected(page)
    page |> Shared.locator(:user_email_input) |> Locator.fill!(Shared.corrected_email())
    Shared.click(page, :save_changes)
    wait_for_live_view_settled(page)

    # Navigate back to dashboard: conflict email is gone; retry succeeds.
    Page.goto!(page, "/bo/dashboard")
    wait_for_live_view_connected(page)
    Shared.click(page, :activate_button)
    page |> Shared.locator(:accept_consent) |> Expect.to_be_visible!()
    Shared.click(page, :accept_consent)
    wait_for_live_view_settled(page)

    Shared.verify_post_accept_modal(page)
    Shared.click(page, :got_it_button)
    wait_for_live_view_settled(page)

    page |> Shared.locator(:activate_button) |> Expect.to_have_count!(0)

    Shared.verify_zaq_router(req, true)
  end

  test "Scenario 5 — email conflict in modal: user fixes email in place, retry succeeds", %{
    page: page,
    req: req
  } do
    # Seed a declined user with NO email: the modal will show the email input.
    user = create_e2e_declined_portal_user(req)
    register_e2e_portal_conflict(req, %{email: Shared.conflict_email()})

    login_to_back_office(page, username: user["username"], password: user["password"])
    Expect.to_have_url!(page, ~r{/bo/dashboard})
    wait_for_live_view_connected(page)

    Shared.click(page, :activate_button)

    # Email input appears because user.email is nil.
    page |> Shared.locator(:modal_email_input) |> Expect.to_be_visible!()

    # Enter the conflicted email -> first accept fails with 409.
    page |> Shared.locator(:modal_email_input) |> Locator.fill!(Shared.conflict_email())
    wait_for_live_view_settled(page)
    Shared.click(page, :accept_consent)
    wait_for_live_view_settled(page)

    page |> Page.get_by_text("already registered in the user portal") |> Expect.to_be_visible!()

    # Correct the email in the same modal: no page navigation needed.
    page |> Shared.locator(:modal_email_input) |> Locator.fill!(Shared.corrected_email())
    wait_for_live_view_settled(page)
    Shared.click(page, :accept_consent)
    wait_for_live_view_settled(page)

    Shared.verify_post_accept_modal(page)
    Shared.click(page, :got_it_button)
    wait_for_live_view_settled(page)

    page |> Shared.locator(:activate_button) |> Expect.to_have_count!(0)

    Shared.verify_zaq_router(req, true)
  end

  test "Scenario 9 — email conflict for user with existing email: 409 shows get-your-key guidance, no inline input",
       %{page: page, req: req} do
    # The user already has an email on file: the modal hides the email input. A 409 means that
    # email is already provisioned in the portal, so the modal surfaces fixed guidance.
    user = create_e2e_declined_portal_user(req, %{email: Shared.conflict_email()})
    register_e2e_portal_conflict(req, %{email: Shared.conflict_email()})

    login_to_back_office(page, username: user["username"], password: user["password"])
    Expect.to_have_url!(page, ~r{/bo/dashboard})
    wait_for_live_view_connected(page)

    # Open modal: email input is NOT present (user has an email on file).
    Shared.click(page, :activate_button)
    page |> Shared.locator(:accept_consent) |> Expect.to_be_visible!()
    page |> Shared.locator(:modal_email_input) |> Expect.to_have_count!(0)

    # First accept -> portal returns 409 -> fixed guidance is shown.
    Shared.click(page, :accept_consent)
    wait_for_live_view_settled(page)

    page |> Page.get_by_text("already registered in the user portal") |> Expect.to_be_visible!()

    # No inline email input is revealed; the modal stays open with the guidance.
    page |> Shared.locator(:modal_email_input) |> Expect.to_have_count!(0)
    page |> Shared.locator(:accept_consent) |> Expect.to_be_visible!()
  end
end
