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

      assert has_element?(view, "#portal-consent button", "Activate")
      assert render(view) =~ "Claim your $2 in free AI credits"
    end

    test "renders offline notice when portal is unreachable", %{conn: conn} do
      Zaq.PortalStubs.stub_portal_unreachable()
      conn = conn_for_portal_user(conn, "declined")

      {:ok, _view, html} = live(conn, ~p"/bo/dashboard")

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

  defp conn_for_portal_user(conn, portal_consent) do
    user = user_fixture(%{username: "portal_#{System.unique_integer([:positive])}"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [portal_consent: portal_consent]
    )

    init_test_session(conn, %{user_id: user.id})
  end
end
