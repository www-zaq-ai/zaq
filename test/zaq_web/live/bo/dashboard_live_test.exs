defmodule ZaqWeb.Live.BO.DashboardLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  import Ecto.Query

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Addons.FeatureStore
  alias Zaq.License.FeatureStore
  alias Zaq.Repo

  setup %{conn: conn} do
    Zaq.PortalStubs.stub_portal_reachable()

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

      assert has_element?(view, "#dashboard-metric-documents-ingested[href='/bo/ingestion']")

      assert has_element?(
               view,
               "#dashboard-metric-documents-ingested",
               "Documents ingested"
             )

      assert has_element?(view, "#dashboard-metric-llm-api-calls[href='/bo/ai-diagnostics']")

      assert has_element?(
               view,
               "#dashboard-metric-llm-api-calls",
               "LLM API calls"
             )

      assert has_element?(
               view,
               "#dashboard-llm-performance-link[href='/bo/dashboard/llm-performance']"
             )

      assert has_element?(
               view,
               "#dashboard-conversations-metrics-link[href='/bo/dashboard/conversations-metrics']"
             )

      assert has_element?(
               view,
               "#dashboard-knowledge-base-metrics-link[href='/bo/dashboard/knowledge-base-metrics']"
             )

      assert has_element?(view, "#dashboard-metric-qa-response-time[href='/bo/chat']")
      assert has_element?(view, "#dashboard-metric-qa-response-time-card")

      assert has_element?(view, "#dashboard-metric-documents-ingested", "range: 30d")
    end

    test "shows bo service as active since endpoint is running", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/bo/dashboard")
      # ZaqWeb.Endpoint is running in test, so bo should be active
      assert html =~ "Back Office"
    end

    test "renders add-ons card with computed days left for valid expiry", %{conn: conn} do
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

    test "handles invalid add-on expiry timestamp", %{conn: conn} do
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

  describe "portal consent email capture" do
    setup %{conn: conn} do
      # An "old" account: declined portal consent and has no email on file.
      user = user_fixture(%{username: "oldadmin"})
      {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [email: nil, portal_consent: "declined"]
      )

      user = Accounts.get_user!(user.id)
      conn = conn |> init_test_session(%{user_id: user.id})

      %{conn: conn, user: user}
    end

    test "omits email input and enables accept when user already has an email", %{conn: conn} do
      # Override the no-email setup with an account that has an email on file.
      user = user_fixture(%{username: "hasemail", email: "has@example.com"})
      {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
      conn = conn |> init_test_session(%{user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
      render_click(view, "show_portal_consent", %{})

      refute has_element?(view, "#portal-consent-email")
      refute has_element?(view, "button[disabled]", "Accept")
    end

    test "renders email input and disables accept when user has no email", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      html = render_click(view, "show_portal_consent", %{})

      assert html =~ "enter it to continue"
      assert has_element?(view, "#portal-consent-email")
      assert has_element?(view, "button[disabled]", "Accept")
    end

    test "enables accept once a non-blank email is entered", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
      render_click(view, "show_portal_consent", %{})

      render_change(view, "portal_consent_email_change", %{"email" => "new@example.com"})

      refute has_element?(view, "button[disabled]", "Accept")
    end

    test "shows a validation error when the entered email is invalid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
      render_click(view, "show_portal_consent", %{})
      render_change(view, "portal_consent_email_change", %{"email" => "not-an-email"})

      html = render_click(view, "accept_portal_consent", %{})

      assert html =~ "Email must be a valid email address."
    end

    test "provisions the portal with the entered email for old users", %{conn: conn, user: user} do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/health/liveliness"} ->
            Req.Test.json(conn, "I'm alive!")

          {"GET", "/onboarding/" <> _} ->
            Req.Test.json(conn, Zaq.PortalStubs.onboarding_response())

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

      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
      render_click(view, "show_portal_consent", %{})
      render_change(view, "portal_consent_email_change", %{"email" => "claimed@example.com"})

      html = render_click(view, "accept_portal_consent", %{})

      assert html =~ "Free credits activated"
      assert Accounts.get_user!(user.id).email == "claimed@example.com"
    end

    test "provisions the portal without changing an existing user email", %{conn: conn} do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/health/liveliness"} ->
            Req.Test.json(conn, "I'm alive!")

          {"GET", "/onboarding/" <> _} ->
            Req.Test.json(conn, Zaq.PortalStubs.onboarding_response())

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

      user = user_fixture(%{username: "portalready", email: "ready@example.com"})
      {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
      conn = conn |> init_test_session(%{user_id: user.id})

      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
      render_click(view, "show_portal_consent", %{})

      html = render_click(view, "accept_portal_consent", %{})

      assert html =~ "Free credits activated"
      assert Accounts.get_user!(user.id).email == "ready@example.com"
    end

    test "closes the portal consent modal when close event is fired", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      render_click(view, "show_portal_consent", %{})
      assert has_element?(view, "#portal-consent-email")

      render_click(view, "close_portal_consent_modal", %{})
      refute has_element?(view, "#portal-consent-email")
    end

    test "shows network error when portal HTTP call fails", %{conn: conn} do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/health/liveliness"} ->
            Req.Test.json(conn, "I'm alive!")

          {"GET", "/onboarding/" <> _} ->
            Req.Test.json(conn, Zaq.PortalStubs.onboarding_response())

          {"POST", "/onboarding"} ->
            Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")
      render_click(view, "show_portal_consent", %{})
      render_change(view, "portal_consent_email_change", %{"email" => "retry@example.com"})

      html = render_click(view, "accept_portal_consent", %{})

      assert html =~ "Could not reach the ZAQ portal"
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

  describe "service detection and telemetry fallback" do
    # Later: If these tests become order-sensitive, move the dashboard runtime
    # seams off Application env and onto a LiveView-local or gateway seam like
    # SystemConfigLive's router injection.
    setup do
      original = %{
        node_list_fun: Application.get_env(:zaq, :dashboard_live_node_list_fun),
        supervisor_running_on_node_fun:
          Application.get_env(:zaq, :dashboard_live_supervisor_running_on_node_fun),
        node_router_module: Application.get_env(:zaq, :dashboard_live_node_router_module)
      }

      on_exit(fn ->
        restore_dashboard_runtime_env(original)
      end)

      :ok
    end

    test "detects a remote supervisor when only a peer reports it", %{conn: conn} do
      remote_node = :remote@localhost

      Application.put_env(:zaq, :dashboard_live_node_list_fun, fn -> [remote_node] end)

      Application.put_env(
        :zaq,
        :dashboard_live_supervisor_running_on_node_fun,
        fn
          node, Zaq.Engine.Supervisor when node == node() -> nil
          ^remote_node, Zaq.Engine.Supervisor -> {true, remote_node}
          _node, _supervisor -> nil
        end
      )

      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      state = :sys.get_state(view.pid)
      engine_service = Enum.find(state.socket.assigns.services, &(&1.role == :engine))

      assert engine_service.active
      assert engine_service.node == remote_node
    end

    test "falls back to default telemetry cards when the router returns an unexpected payload", %{
      conn: conn
    } do
      Application.put_env(
        :zaq,
        :dashboard_live_node_router_module,
        ZaqWeb.Live.BO.DashboardLiveTest.UnexpectedTelemetryRouter
      )

      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      state = :sys.get_state(view.pid)

      assert length(state.socket.assigns.metric_cards) == 3
      assert Enum.at(state.socket.assigns.metric_cards, 0).label == "Documents ingested"
    end

    test "falls back to default telemetry cards when the router raises", %{conn: conn} do
      Application.put_env(
        :zaq,
        :dashboard_live_node_router_module,
        ZaqWeb.Live.BO.DashboardLiveTest.RaisingTelemetryRouter
      )

      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      state = :sys.get_state(view.pid)

      assert length(state.socket.assigns.metric_cards) == 3
      assert Enum.at(state.socket.assigns.metric_cards, 1).label == "LLM API calls"
    end
  end

  defp restore_dashboard_runtime_env(original) do
    Enum.each(original, fn
      {key, nil} ->
        Application.delete_env(:zaq, key)

      {key, value} ->
        Application.put_env(:zaq, key, value)
    end)
  end
end

defmodule ZaqWeb.Live.BO.DashboardLiveTest.UnexpectedTelemetryRouter do
  def invoke(:engine, Zaq.Engine.Telemetry, :load_main_dashboard_metrics, [_params]) do
    %{unexpected: :payload}
  end
end

defmodule ZaqWeb.Live.BO.DashboardLiveTest.RaisingTelemetryRouter do
  def invoke(:engine, Zaq.Engine.Telemetry, :load_main_dashboard_metrics, [_params]) do
    raise "telemetry unavailable"
  end
end
