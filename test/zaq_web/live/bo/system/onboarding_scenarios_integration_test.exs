defmodule ZaqWeb.Live.BO.System.OnboardingScenariosIntegrationTest do
  @moduledoc """
  Integration variants of the onboarding scenario tests that exercise the real
  `Zaq.UserPortal.Client` HTTP layer instead of the Mox mock.

  Each scenario is identical in intent to `OnboardingScenariosTest` but all HTTP
  calls go through the real client code: JSON encoding, response-body parsing,
  HTTP status pattern-matching, and error extraction are all exercised. `Req.Test`
  intercepts at the transport layer so no real network calls are made.

  This means a bug in `Client.fetch_onboarding/1` or `Client.onboard_user/1` —
  wrong JSON key, bad status handling, missing field — will surface here but not
  in the Mox-based scenario tests (which never touch the client code at all).
  """

  use ZaqWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo

  @moduletag :onboarding_scenarios_integration

  @password "StrongPass1!"
  @email "admin@zaq.local"
  @alt_email "alt.admin@zaq.local"

  # Mirrors the exact shape the real ZAQ User Portal returns.
  @metadata_response %{
    "status" => "ok",
    "message" => %{
      "plan_status" => "enabled",
      "available" => true,
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

  # Mirrors the exact shape the real portal returns on a successful onboard.
  @success_response %{
    "status" => "ok",
    "user" => %{
      "litellm_api_key" => "sk-e2e-portal-key",
      "litellm_user_id" => "llm-user-e2e"
    }
  }

  @api_key "sk-e2e-portal-key"

  setup do
    # Switch from the Mox mock to the real HTTP client for the duration of this test.
    # Capture the configured default first so on_exit restores the *actual* value
    # (Zaq.UserPortal.ClientMock) rather than hardcoding it — restoring the wrong
    # client here clobbers the default for every subsequent test in the run.
    original_client = Application.get_env(:zaq, :user_portal_client)

    Application.put_env(:zaq, :user_portal_client, Zaq.UserPortal.Client)
    # Route all Req HTTP calls through the Req.Test plug — no real network requests.
    Application.put_env(:zaq, Zaq.UserPortal.Client,
      req_options: [plug: {Req.Test, Zaq.UserPortal.Client}]
    )

    on_exit(fn ->
      Application.put_env(:zaq, :user_portal_client, original_client)
      Application.delete_env(:zaq, Zaq.UserPortal.Client)
    end)

    # Default stub: reachable + onboard succeeds. Individual tests override as needed.
    stub_portal_reachable()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Scenario 1 — Portal unreachable at bootstrap
  # ---------------------------------------------------------------------------
  # Transport error on every request. The client must return :unavailable, the
  # LiveView must skip the modal, scaffold a keyless credential, and redirect to
  # the dashboard. The dashboard shows the "unreachable" notice.
  # ---------------------------------------------------------------------------

  describe "Scenario 1 — portal unreachable at bootstrap" do
    setup do
      stub_portal_unreachable()
      :ok
    end

    test "skips modal, scaffolds keyless ZAQ Router, wires no model configs, shows unreachable notice",
         %{conn: conn} do
      user = user_fixture(%{username: "i1_#{uid()}", email: @email})
      conn = init_test_session(conn, %{user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/bo/change-password")
      submit_bootstrap_form(view)

      flash = assert_redirect(view, ~p"/bo/dashboard")
      assert flash["info"] =~ "Password changed"

      updated = Accounts.get_user!(user.id)
      refute updated.must_change_password
      assert updated.portal_consent == "declined"

      credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential != nil
      assert is_nil(credential.api_key)

      assert is_nil(Zaq.System.get_llm_config().credential_id)
      assert is_nil(Zaq.System.get_embedding_config().credential_id)
      assert is_nil(Zaq.System.get_image_to_text_config().credential_id)

      # Portal metadata is fetched asynchronously after connect, so await it.
      {:ok, view2, _html2} = live(fresh_conn(user), ~p"/bo/dashboard")
      html2 = render_async(view2)
      assert html2 =~ "ZAQ portal is not reachable in this environment"
      refute html2 =~ "Activate"
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 2 — User accepts portal consent at bootstrap (happy path)
  # ---------------------------------------------------------------------------
  # Portal returns a 200 with a real litellm_api_key. The client must parse the
  # key correctly. Provisioner must wire all three model configs.
  # ---------------------------------------------------------------------------

  describe "Scenario 2 — user accepts portal consent at bootstrap" do
    test "provisions ZAQ Router with API key, wires all model configs, redirects to ingestion",
         %{conn: conn} do
      user = user_fixture(%{username: "i2_#{uid()}", email: @email})
      conn = init_test_session(conn, %{user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/bo/change-password")
      submit_bootstrap_form(view)

      assert has_element?(view, "[phx-click='accept_portal_consent']")
      render_click(view, "accept_portal_consent")
      render_click(view, "close_post_accept_modal")

      flash = assert_redirect(view, ~p"/bo/ingestion")
      assert flash["info"] =~ "drop your files"

      updated = Accounts.get_user!(user.id)
      refute updated.must_change_password
      assert updated.portal_consent == "accepted"

      credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential != nil
      assert credential.api_key == @api_key

      assert Zaq.System.get_llm_config().credential_id == credential.id
      assert Zaq.System.get_embedding_config().credential_id == credential.id
      assert Zaq.System.get_image_to_text_config().credential_id == credential.id

      {:ok, _view2, html2} = live(fresh_conn(user), ~p"/bo/dashboard")
      refute html2 =~ "Activate"
      refute html2 =~ "Activate your free credits"
      refute html2 =~ "portal-consent-email"
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 3 — User declines at bootstrap, retries from dashboard
  # ---------------------------------------------------------------------------
  # The client is never called for onboard on the decline path. The retry accept
  # must parse the response correctly and create the credential.
  # ---------------------------------------------------------------------------

  describe "Scenario 3 — user declines at bootstrap, retries from dashboard" do
    test "decline leaves no credential; dashboard banner lets user accept later",
         %{conn: conn} do
      user = user_fixture(%{username: "i3_#{uid()}", email: @email})
      conn = init_test_session(conn, %{user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/bo/change-password")
      submit_bootstrap_form(view)

      assert has_element?(view, "[phx-click='decline_portal_consent']")
      render_click(view, "decline_portal_consent")

      flash = assert_redirect(view, ~p"/bo/dashboard")
      assert flash["info"] =~ "Password changed"

      updated = Accounts.get_user!(user.id)
      assert updated.portal_consent == "declined"
      keyless_cred = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert keyless_cred != nil
      assert is_nil(keyless_cred.api_key)
      assert is_nil(Zaq.System.get_llm_config().credential_id)

      {:ok, view2, _html2} = live(fresh_conn(user), ~p"/bo/dashboard")
      render_async(view2)
      assert has_element?(view2, "#portal-consent button", "Activate")
      assert render(view2) =~ "Claim your $2"

      view2 |> element("#portal-consent button", "Activate") |> render_click()
      view2 |> element("[phx-click='accept_portal_consent']") |> render_click()

      retried = Accounts.get_user!(user.id)
      assert retried.portal_consent == "accepted"

      credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential != nil
      assert credential.api_key == @api_key
      assert Zaq.System.get_llm_config().credential_id == credential.id
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 4 — Wrong email at dashboard retry, admin corrects email, retry succeeds
  # ---------------------------------------------------------------------------
  # Portal returns a real 409 JSON body. The client must surface the "message"
  # field from the body. After email correction, a real 200 response must be
  # parsed and the credential created.
  # ---------------------------------------------------------------------------

  describe "Scenario 4 — wrong email at dashboard retry, correct email externally, retry succeeds" do
    test "portal 409 surfaces error; correcting email in DB and retrying provisions successfully",
         %{conn: conn} do
      user = declined_registered_user(%{username: "i4_#{uid()}", email: "wrong@zaq.local"})

      # First attempt: portal returns a real 409 JSON error body
      stub_onboard_error(409, %{"message" => "A user with this email is already provisioned."})

      {:ok, view, _html} = live(init_test_session(conn, %{user_id: user.id}), ~p"/bo/dashboard")
      render_async(view)
      view |> element("#portal-consent button", "Activate") |> render_click()
      html = view |> element("[phx-click='accept_portal_consent']") |> render_click()

      assert html =~ "A user with this email is already provisioned."
      assert Accounts.get_user!(user.id).portal_consent == "declined"
      assert is_nil(Zaq.System.get_ai_provider_credential_by_name("ZAQ Router"))

      # Admin corrects the email externally
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [email: @alt_email])

      # Reset stub to return a real 200 success response for the second attempt
      stub_portal_reachable()

      {:ok, view2, _html2} = live(fresh_conn(user), ~p"/bo/dashboard")
      render_async(view2)
      view2 |> element("#portal-consent button", "Activate") |> render_click()
      view2 |> element("[phx-click='accept_portal_consent']") |> render_click()

      accepted = Accounts.get_user!(user.id)
      assert accepted.portal_consent == "accepted"
      assert accepted.email == @alt_email

      credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential.api_key == @api_key
      assert Zaq.System.get_llm_config().credential_id == credential.id
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 5 — Email already in portal; user fixes email in retry modal
  # ---------------------------------------------------------------------------
  # Two onboard calls within the same mounted view. The real client must parse
  # the 409 message field. The stub is updated between the two attempts so each
  # call gets the correct real HTTP response.
  # ---------------------------------------------------------------------------

  describe "Scenario 5 — email already in portal, user fixes email in retry modal" do
    test "409 surfaces in modal; changing email in same modal and retrying provisions successfully",
         %{conn: conn} do
      user = declined_user_no_email(%{username: "i5_#{uid()}"})

      # First accept: real 409 response body — client must extract the "message" field
      stub_onboard_error(409, %{"message" => "A user with this email is already provisioned."})

      {:ok, view, _html} = live(init_test_session(conn, %{user_id: user.id}), ~p"/bo/dashboard")
      render_async(view)
      view |> element("#portal-consent button", "Activate") |> render_click()

      assert has_element?(view, "#portal-consent-email")

      view
      |> element("form[phx-change='portal_consent_email_change']")
      |> render_change(%{"email" => "taken@zaq.local"})

      html = view |> element("[phx-click='accept_portal_consent']") |> render_click()
      assert html =~ "A user with this email is already provisioned."

      # Failed attempt commits nothing: email and consent unchanged
      assert is_nil(Accounts.get_user!(user.id).email)
      assert Accounts.get_user!(user.id).portal_consent == "declined"

      # Swap stub to return a real 200 for the corrected email
      stub_portal_reachable()

      view
      |> element("form[phx-change='portal_consent_email_change']")
      |> render_change(%{"email" => @alt_email})

      view |> element("[phx-click='accept_portal_consent']") |> render_click()

      accepted = Accounts.get_user!(user.id)
      assert accepted.portal_consent == "accepted"
      assert accepted.email == @alt_email

      credential = Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential.api_key == @api_key
      assert Zaq.System.get_llm_config().credential_id == credential.id
    end
  end

  # ---------------------------------------------------------------------------
  # Req.Test stub helpers — control HTTP responses from the real client
  # ---------------------------------------------------------------------------

  # Portal reachable: GET /onboarding/free → 200 metadata, POST /onboarding → 200 success.
  defp stub_portal_reachable do
    Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
      case conn.request_path do
        "/onboarding/free" -> Req.Test.json(conn, @metadata_response)
        "/onboarding" -> Req.Test.json(conn, @success_response)
      end
    end)
  end

  # Portal unreachable: every request gets a transport error.
  defp stub_portal_unreachable do
    Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)
  end

  # Portal reachable for metadata, but POST /onboarding returns `status` + `body`.
  defp stub_onboard_error(status, body) do
    Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
      case conn.request_path do
        "/onboarding/free" ->
          Req.Test.json(conn, @metadata_response)

        "/onboarding" ->
          conn
          |> Plug.Conn.put_status(status)
          |> Req.Test.json(body)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # LiveView / DB helpers (identical to the Mox scenario test)
  # ---------------------------------------------------------------------------

  defp uid, do: :erlang.unique_integer([:positive])

  defp fresh_conn(user), do: init_test_session(build_conn(), %{user_id: user.id})

  defp submit_bootstrap_form(view) do
    view
    |> form("#change-password-form", %{
      "password" => @password,
      "password_confirmation" => @password
    })
    |> render_submit()
  end

  defp declined_registered_user(attrs) do
    user = user_fixture(attrs)
    {:ok, user} = Accounts.change_password(user, %{password: @password})

    Repo.update_all(
      from(u in User, where: u.id == ^user.id),
      set: [portal_consent: "declined", must_change_password: false]
    )

    Accounts.get_user!(user.id)
  end

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
