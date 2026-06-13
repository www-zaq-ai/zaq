defmodule ZaqWeb.Live.BO.PortalConsentLiveTest do
  use ZaqWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo

  describe "render states" do
    test "renders retry banner when consent was declined and portal is reachable", %{conn: conn} do
      Zaq.PortalStubs.stub_portal_reachable()
      conn = conn_for_portal_user(conn, "declined")

      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      # Portal metadata is fetched asynchronously after connect — await it.
      html = render_async(view)
      assert has_element?(view, "#portal-consent button", "Activate")
      assert html =~ "Claim your $2 in free AI credits"
    end

    test "renders offline notice when portal is unreachable", %{conn: conn} do
      Zaq.PortalStubs.stub_portal_unreachable()
      conn = conn_for_portal_user(conn, "declined")

      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      html = render_async(view)
      assert html =~ "ZAQ portal is not reachable in this environment"
      refute html =~ "Activate"
    end

    test "does not render modal or banner when consent was accepted", %{conn: conn} do
      Zaq.PortalStubs.stub_portal_reachable()
      conn = conn_for_portal_user(conn, "accepted")

      {:ok, _view, html} = live(conn, ~p"/bo/dashboard")

      refute html =~ "Activate"
      refute html =~ "Activate your free credits"
      refute html =~ "portal-consent-email"
    end
  end

  describe "portal request gating" do
    test "contacts the portal once for a banner-eligible (declined) user", %{conn: conn} do
      test_pid = self()

      Mox.stub(Zaq.UserPortal.ClientMock, :fetch_onboarding, fn _slug ->
        send(test_pid, :portal_fetched)
        {:ok, Zaq.PortalStubs.onboarding_message()}
      end)

      conn = conn_for_portal_user(conn, "declined")
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
      render_async(view)

      assert_receive :portal_fetched, 1_000
    end

    test "never contacts the portal once consent has been accepted", %{conn: conn} do
      test_pid = self()

      Mox.stub(Zaq.UserPortal.ClientMock, :fetch_onboarding, fn _slug ->
        send(test_pid, :portal_fetched)
        {:ok, Zaq.PortalStubs.onboarding_message()}
      end)

      conn = conn_for_portal_user(conn, "accepted")
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
      # render_async settles any pending async work. For an accepted user none is
      # started, so this returns immediately; if the eligibility gate regressed,
      # the fetch task would be awaited here and :portal_fetched would arrive.
      render_async(view)

      refute_received :portal_fetched
    end
  end

  describe "accept_portal_consent error messaging" do
    test "surfaces the portal's own message on a non-200 response", %{conn: conn} do
      Zaq.PortalStubs.stub_portal_onboard_error(409, %{
        "error" => "user_already_exists",
        "message" => "A user with this email is already provisioned."
      })

      conn = conn_for_portal_user(conn, "declined")
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
      render_async(view)

      view |> element("#portal-consent button", "Activate") |> render_click()
      html = view |> element("button", "Accept") |> render_click()

      assert html =~ "A user with this email is already provisioned."
      refute html =~ "Could not reach the ZAQ portal"
    end

    test "falls back to a generic message on transport failure", %{conn: conn} do
      Mox.stub(Zaq.UserPortal.ClientMock, :fetch_onboarding, fn _slug ->
        {:ok, Zaq.PortalStubs.onboarding_message()}
      end)

      Mox.stub(Zaq.UserPortal.ClientMock, :onboard_user, fn _email ->
        {:error, :econnrefused}
      end)

      conn = conn_for_portal_user(conn, "declined")
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
      render_async(view)

      view |> element("#portal-consent button", "Activate") |> render_click()
      html = view |> element("button", "Accept") |> render_click()

      assert html =~ "Could not reach the ZAQ portal. Please try again later."
    end
  end

  defp conn_for_portal_user(conn, portal_consent) do
    user = user_fixture(%{username: "portal_#{System.unique_integer([:positive])}"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [portal_consent: portal_consent]
    )

    init_test_session(conn, %{user_id: user.id})
  end
end
