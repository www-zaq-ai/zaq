defmodule ZaqWeb.Live.BO.System.OnboardingScenariosTest do
  @moduledoc """
  Scenario (journey-level) tests for the bootstrap onboarding flow.

  Each test walks a complete user story end-to-end: empty DB → change-password →
  consent decision → final stable state. DB state is verified directly via
  `Zaq.System.*` and `Repo` queries at every checkpoint, not just UI text.

  These tests complement — but do not replace — the unit-level tests in
  `change_password_live_test.exs` and `portal_consent_live_test.exs`.
  """

  use ZaqWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo

  setup :verify_on_exit!

  @moduletag :onboarding_scenarios

  @password "StrongPass1!"
  @email "admin@zaq.local"
  @alt_email "alt.admin@zaq.local"

  # ---------------------------------------------------------------------------
  # Scenario 1 — Portal unreachable at bootstrap
  # ---------------------------------------------------------------------------
  # The very first admin fills change-password while the portal is down.
  # No consent modal is shown. Registration persists, consent is "declined", a
  # keyless ZAQ Router credential is scaffolded, and no model configs are wired.
  # The dashboard shows the "unreachable" notice rather than an Activate banner.
  # ---------------------------------------------------------------------------

  describe "Scenario 1 — portal unreachable at bootstrap" do
    setup do
      Zaq.PortalStubs.stub_portal_unreachable()
      :ok
    end

    test "skips modal, scaffolds keyless ZAQ Router, wires no model configs, shows unreachable notice",
         %{conn: conn} do
      user = user_fixture(%{username: "s1_#{uid()}", email: @email})
      conn = init_test_session(conn, %{user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/bo/change-password")

      # Portal unreachable → LiveView redirects to the dashboard once the async
      # portal fetch resolves to :unavailable (no modal). The redirect itself is
      # proof the modal was never shown: if a modal were rendered, the view would
      # stay mounted waiting for accept/decline.
      submit_bootstrap_form(view)

      flash = assert_redirect(view, ~p"/bo/dashboard", 1000)
      assert flash["info"] =~ "Password changed"

      # Registration persisted
      updated = Accounts.get_user!(user.id)
      refute updated.must_change_password
      assert updated.portal_consent == "declined"

      # Keyless ZAQ Router credential scaffolded (provider listed, not configured)
      credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential != nil
      assert is_nil(credential.api_key)

      # No model configs wired to the keyless credential
      assert is_nil(Zaq.System.get_llm_config().credential_id)
      assert is_nil(Zaq.System.get_embedding_config().credential_id)
      assert is_nil(Zaq.System.get_image_to_text_config().credential_id)

      # Dashboard shows unreachable notice, not the Activate banner. The portal
      # metadata is fetched asynchronously after connect, so await it.
      {:ok, view2, _html2} = live(fresh_conn(user), ~p"/bo/dashboard")
      html2 = render_async(view2)
      assert html2 =~ "ZAQ portal is not reachable in this environment"
      refute html2 =~ "Activate"
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 2 — User accepts portal consent at bootstrap (happy path)
  # ---------------------------------------------------------------------------
  # Admin fills change-password, sees the consent modal, accepts. Provisioning
  # succeeds. Redirected to ingestion with a welcome flash. ZAQ Router has a
  # real API key and all three model configs are wired. Dashboard shows no banner.
  # ---------------------------------------------------------------------------

  describe "Scenario 2 — user accepts portal consent at bootstrap" do
    setup do
      Zaq.PortalStubs.stub_portal_reachable()
      :ok
    end

    test "provisions ZAQ Router with API key, wires all model configs, redirects to ingestion",
         %{conn: conn} do
      user = user_fixture(%{username: "s2_#{uid()}", email: @email})
      conn = init_test_session(conn, %{user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/bo/change-password")
      submit_bootstrap_form(view)

      # Consent modal must appear after form submit
      assert has_element?(view, "[phx-click='accept_portal_consent']")

      render_click(view, "accept_portal_consent")
      render_click(view, "close_post_accept_modal")

      flash = assert_redirect(view, ~p"/bo/ingestion")
      assert flash["info"] =~ "drop your files"

      # Registration + consent persisted
      updated = Accounts.get_user!(user.id)
      refute updated.must_change_password
      assert updated.portal_consent == "accepted"

      # ZAQ Router credential with the real API key returned by the portal stub
      credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential != nil
      assert credential.api_key == "sk-test-key"

      # All three model configs wired to the new credential
      assert Zaq.System.get_llm_config().credential_id == credential.id
      assert Zaq.System.get_embedding_config().credential_id == credential.id
      assert Zaq.System.get_image_to_text_config().credential_id == credential.id

      # Dashboard: accepted users see no portal banner or modal
      {:ok, _view2, html2} = live(fresh_conn(user), ~p"/bo/dashboard")
      refute html2 =~ "Activate"
      refute html2 =~ "Activate your free credits"
      refute html2 =~ "portal-consent-email"
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 3 — User declines at bootstrap, retries from dashboard
  # ---------------------------------------------------------------------------
  # Admin declines the consent modal at change-password time. No credential is
  # created. Dashboard shows the Activate banner. Admin clicks Activate, accepts
  # in the retry modal. Provisioning succeeds; credential and configs are created.
  # ---------------------------------------------------------------------------

  describe "Scenario 3 — user declines at bootstrap, retries from dashboard" do
    setup do
      Zaq.PortalStubs.stub_portal_reachable()
      :ok
    end

    test "decline leaves no credential; dashboard banner lets user accept later",
         %{conn: conn} do
      user = user_fixture(%{username: "s3_#{uid()}", email: @email})
      conn = init_test_session(conn, %{user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/bo/change-password")
      submit_bootstrap_form(view)

      assert has_element?(view, "[phx-click='decline_portal_consent']")
      render_click(view, "decline_portal_consent")

      flash = assert_redirect(view, ~p"/bo/dashboard")
      assert flash["info"] =~ "Password changed"

      # DB after decline: consent recorded, keyless credential scaffolded, no model configs wired
      updated = Accounts.get_user!(user.id)
      assert updated.portal_consent == "declined"
      keyless_cred = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert keyless_cred != nil
      assert is_nil(keyless_cred.api_key)
      assert is_nil(Zaq.System.get_llm_config().credential_id)

      # Dashboard: Activate banner present with offer copy (fetched async).
      {:ok, view2, _html2} = live(fresh_conn(user), ~p"/bo/dashboard")
      render_async(view2)
      assert has_element?(view2, "#portal-consent button", "Activate")
      assert render(view2) =~ "Claim your $2"

      # User opens modal and accepts
      view2 |> element("#portal-consent button", "Activate") |> render_click()
      view2 |> element("[phx-click='accept_portal_consent']") |> render_click()

      # DB: portal now accepted, credential and configs created
      retried = Accounts.get_user!(user.id)
      assert retried.portal_consent == "accepted"

      credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential != nil
      assert credential.api_key == "sk-test-key"
      assert Zaq.System.get_llm_config().credential_id == credential.id
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 4 — Wrong email at dashboard retry, admin corrects email, retry succeeds
  # ---------------------------------------------------------------------------
  # A declined registered user goes to the dashboard, tries to activate with the
  # wrong email (portal returns 409). Error shown in modal. Admin corrects the
  # email externally (user management). User remounts the dashboard — the component
  # now picks up the corrected email — accepts; provisioning succeeds.
  # ---------------------------------------------------------------------------

  describe "Scenario 4 — wrong email at dashboard retry, correct email externally, retry succeeds" do
    test "portal 409 surfaces error; correcting email in DB and retrying provisions successfully",
         %{conn: conn} do
      user = declined_registered_user(%{username: "s4_#{uid()}", email: "wrong@zaq.local"})

      # First attempt: portal rejects the user's current email
      Mox.stub(Zaq.UserPortal.ClientMock, :fetch_onboarding, fn _slug ->
        {:ok, Zaq.PortalStubs.onboarding_message()}
      end)

      Mox.expect(Zaq.UserPortal.ClientMock, :onboard_user, fn "wrong@zaq.local" ->
        {:error, {409, %{"message" => "A user with this email is already provisioned."}}}
      end)

      {:ok, view, _html} = live(init_test_session(conn, %{user_id: user.id}), ~p"/bo/dashboard")
      render_async(view)
      view |> element("#portal-consent button", "Activate") |> render_click()
      html = view |> element("[phx-click='accept_portal_consent']") |> render_click()

      assert html =~ "A user with this email is already provisioned."

      # DB unchanged after failed attempt
      assert Accounts.get_user!(user.id).portal_consent == "declined"
      assert is_nil(Zaq.System.get_ai_provider_credential_by_name("ZAQ Router"))

      # Admin corrects the email via user management (external to the current session)
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [email: @alt_email])

      # Second attempt: corrected email accepted by portal
      Mox.expect(Zaq.UserPortal.ClientMock, :onboard_user, fn "alt.admin@zaq.local" ->
        {:ok, %{litellm_api_key: "sk-corrected-key"}}
      end)

      {:ok, view2, _html2} = live(fresh_conn(user), ~p"/bo/dashboard")
      render_async(view2)
      view2 |> element("#portal-consent button", "Activate") |> render_click()
      view2 |> element("[phx-click='accept_portal_consent']") |> render_click()

      # DB: accepted, email persisted, credential created
      accepted = Accounts.get_user!(user.id)
      assert accepted.portal_consent == "accepted"
      assert accepted.email == @alt_email

      credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential.api_key == "sk-corrected-key"
      assert Zaq.System.get_llm_config().credential_id == credential.id
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 5 — Email already in portal; user fixes email in retry modal
  # ---------------------------------------------------------------------------
  # A pre-existing user with no email on file opens the portal retry modal,
  # enters an email that the portal already knows (409). The error is shown and
  # the email field stays editable (require_email is true when email is nil).
  # User changes the email inside the modal and retries; provisioning succeeds.
  # The corrected email is persisted on the user record only after success.
  # ---------------------------------------------------------------------------

  describe "Scenario 5 — email already in portal, user fixes email in retry modal" do
    test "409 surfaces in modal; changing email in same modal and retrying provisions successfully",
         %{conn: conn} do
      # Pre-existing account with no email — the retry modal will show the email field
      user = declined_user_no_email(%{username: "s5_#{uid()}"})

      Mox.stub(Zaq.UserPortal.ClientMock, :fetch_onboarding, fn _slug ->
        {:ok, Zaq.PortalStubs.onboarding_message()}
      end)

      # First attempt: taken email → 409
      Mox.expect(Zaq.UserPortal.ClientMock, :onboard_user, fn "taken@zaq.local" ->
        {:error, {409, %{"message" => "A user with this email is already provisioned."}}}
      end)

      {:ok, view, _html} = live(init_test_session(conn, %{user_id: user.id}), ~p"/bo/dashboard")
      render_async(view)

      view |> element("#portal-consent button", "Activate") |> render_click()

      # Email field is shown (user has no email on file)
      assert has_element?(view, "#portal-consent-email")

      # Enter the taken email and accept
      view
      |> element("form[phx-change='portal_consent_email_change']")
      |> render_change(%{"email" => "taken@zaq.local"})

      html = view |> element("[phx-click='accept_portal_consent']") |> render_click()

      assert html =~ "A user with this email is already provisioned."

      # Modal stays open; user's email and consent unchanged (failed attempt commits nothing)
      assert is_nil(Accounts.get_user!(user.id).email)
      assert Accounts.get_user!(user.id).portal_consent == "declined"

      # Second attempt: correct email accepted by portal
      Mox.expect(Zaq.UserPortal.ClientMock, :onboard_user, fn "alt.admin@zaq.local" ->
        {:ok, %{litellm_api_key: "sk-new-email-key"}}
      end)

      view
      |> element("form[phx-change='portal_consent_email_change']")
      |> render_change(%{"email" => @alt_email})

      view |> element("[phx-click='accept_portal_consent']") |> render_click()

      # DB: email and consent persisted after successful provisioning
      accepted = Accounts.get_user!(user.id)
      assert accepted.portal_consent == "accepted"
      assert accepted.email == @alt_email

      credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential.api_key == "sk-new-email-key"
      assert Zaq.System.get_llm_config().credential_id == credential.id
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Unique integer suffix for usernames to avoid conflicts within a test run.
  defp uid, do: :erlang.unique_integer([:positive])

  # Fresh conn with a user session for mounting a second page after redirect.
  defp fresh_conn(user) do
    init_test_session(build_conn(), %{user_id: user.id})
  end

  # Submit the change-password form with the standard strong password.
  # Returns the rendered HTML after submit (used to inspect modal presence).
  defp submit_bootstrap_form(view) do
    view
    |> form("#change-password-form", %{
      "password" => @password,
      "password_confirmation" => @password
    })
    |> render_submit()
  end

  # A user who has completed registration but declined portal consent.
  defp declined_registered_user(attrs) do
    user = user_fixture(attrs)
    {:ok, user} = Accounts.change_password(user, %{password: @password})

    Repo.update_all(
      from(u in User, where: u.id == ^user.id),
      set: [portal_consent: "declined", must_change_password: false]
    )

    Accounts.get_user!(user.id)
  end

  # A pre-existing user with no email on file and declined consent.
  # Used to test the email-capture flow in the dashboard retry modal.
  defp declined_user_no_email(attrs) do
    user = user_fixture(attrs)
    {:ok, user} = Accounts.change_password(user, %{password: @password})

    Repo.update_all(
      from(u in User, where: u.id == ^user.id),
      set: [email: nil, portal_consent: "declined", must_change_password: false]
    )

    Accounts.get_user!(user.id)
  end
end
