defmodule ZaqWeb.Live.BO.DashboardLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.License.FeatureStore

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = conn |> init_test_session(%{user_id: user.id})
    FeatureStore.clear()

    on_exit(fn ->
      FeatureStore.clear()
    end)

    %{conn: conn, user: user}
  end

  describe "mount" do
    test "renders the dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/dashboard")
      assert html =~ "Engine"
      assert html =~ "Agent"
      assert html =~ "Ingestion"
      assert html =~ "Channels"
      assert html =~ "Back Office"
    end

    test "shows user count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/dashboard")
      assert html =~ "Users"
    end

    test "shows bo service as active since endpoint is running", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/dashboard")
      # ZaqWeb.Endpoint is running in test, so bo should be active
      assert html =~ "Back Office"
    end

    test "renders license card with computed days left for valid expiry", %{conn: conn} do
      future = DateTime.add(DateTime.utc_now(), 45 * 86_400, :second) |> DateTime.to_iso8601()

      :ok =
        FeatureStore.store(
          %{
            "company_name" => "Acme",
            "license_key" => "lic-123",
            "expires_at" => future,
            "features" => [%{"name" => "ontology"}]
          },
          []
        )

      {:ok, _view, html} = live(conn, ~p"/bo/dashboard")
      assert html =~ "Acme"
      assert html =~ "Days Left"
    end

    test "handles invalid license expiry timestamp", %{conn: conn} do
      :ok =
        FeatureStore.store(
          %{
            "company_name" => "Acme",
            "license_key" => "lic-123",
            "expires_at" => "not-a-date",
            "features" => []
          },
          []
        )

      {:ok, _view, html} = live(conn, ~p"/bo/dashboard")
      assert html =~ "Acme"
      assert html =~ "Days Left"
    end
  end

  describe "node events via PubSub" do
    test "refreshes services on node_up", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      # Simulate PeerConnector broadcasting a node_up event
      Phoenix.PubSub.broadcast(Zaq.PubSub, "node:events", {:node_up, :ai@localhost})

      # Give the LiveView time to process the message
      :timer.sleep(50)

      # Dashboard should still render without crashing
      assert render(view) =~ "Engine"
    end

    test "refreshes services on node_down", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      Phoenix.PubSub.broadcast(Zaq.PubSub, "node:events", {:node_down, :ai@localhost})

      :timer.sleep(50)

      assert render(view) =~ "Engine"
    end

    test "does not crash on unknown node events", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      Phoenix.PubSub.broadcast(Zaq.PubSub, "node:events", {:node_up, :unknown@localhost})

      :timer.sleep(50)

      assert render(view) =~ "Engine"
    end
  end
end
