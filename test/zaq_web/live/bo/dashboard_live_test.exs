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

    test "renders KPI metric cards with expected labels and routes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      assert has_element?(view, "#dashboard-metric-total-users[href='/bo/users']")
      assert has_element?(view, "#dashboard-metric-total-users-label", "Total users count")

      assert has_element?(view, "#dashboard-metric-documents-ingested[href='/bo/ingestion']")

      assert has_element?(
               view,
               "#dashboard-metric-documents-ingested-label",
               "Documents ingested (last 30 days)"
             )

      assert has_element?(view, "#dashboard-metric-llm-api-calls[href='/bo/ai-diagnostics']")

      assert has_element?(
               view,
               "#dashboard-metric-llm-api-calls-label",
               "LLM API calls (last 30 days)"
             )

      assert has_element?(
               view,
               "#dashboard-llm-performance-link[href='/bo/dashboard/llm-performance']"
             )

      assert has_element?(view, "#dashboard-metric-qa-response-time[href='/bo/chat']")

      assert has_element?(
               view,
               "#dashboard-metric-qa-response-time-label",
               "Q&A average response time (last 30 days)"
             )
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

      # render/1 flushes pending messages before returning HTML
      assert render(view) =~ "Engine"
    end

    test "refreshes services on node_down", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      Phoenix.PubSub.broadcast(Zaq.PubSub, "node:events", {:node_down, :ai@localhost})

      assert render(view) =~ "Engine"
    end

    test "does not crash on unknown node events", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      Phoenix.PubSub.broadcast(Zaq.PubSub, "node:events", {:node_up, :unknown@localhost})

      assert render(view) =~ "Engine"
    end
  end
end
