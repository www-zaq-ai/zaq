defmodule ZaqWeb.E2EControllerTest do
  use ZaqWeb.ConnCase, async: false

  import Zaq.AccountsFixtures

  alias Zaq.E2E.LogCollector
  alias Zaq.E2E.PortalState

  setup do
    LogCollector.clear()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Portal loopback — only compiled when E2E=1 (e2e_routes: true).
  # Tagged :integration so they're skipped in plain `mix test` and run
  # automatically when the E2E server is active (routes are compiled in).
  # ---------------------------------------------------------------------------

  describe "GET /e2e/portal/onboarding/:slug" do
    @tag :integration
    test "returns onboarding metadata", %{conn: conn} do
      conn = get(conn, "/e2e/portal/onboarding/free")
      body = json_response(conn, 200)
      assert get_in(body, ["message", "offer_slug"]) == "free"
      assert get_in(body, ["message", "metadata", "title"]) =~ "free credits"
    end
  end

  describe "POST /e2e/portal/onboarding" do
    setup do
      start_supervised!(PortalState)
      :ok
    end

    @tag :integration
    test "returns success by default", %{conn: conn} do
      conn = post(conn, "/e2e/portal/onboarding", %{email: "new@example.com"})
      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert is_binary(body["user"]["litellm_api_key"])
    end

    @tag :integration
    test "returns 409 when email is pre-registered as a conflict", %{conn: conn} do
      PortalState.register_conflict(email: "taken@example.com")
      conn = post(conn, "/e2e/portal/onboarding", %{email: "taken@example.com"})
      body = json_response(conn, 409)
      assert body["message"] =~ "already provisioned"
    end

    @tag :integration
    test "returns 200 for an email that is not in the conflict set", %{conn: conn} do
      PortalState.register_conflict(email: "taken@example.com")
      conn = post(conn, "/e2e/portal/onboarding", %{email: "safe@example.com"})
      assert json_response(conn, 200)["status"] == "ok"
    end
  end

  describe "POST /e2e/portal/conflicts" do
    setup do
      start_supervised!(PortalState)
      :ok
    end

    @tag :integration
    test "registers an email conflict", %{conn: conn} do
      conn = post(conn, "/e2e/portal/conflicts", %{email: "seed@example.com"})
      assert json_response(conn, 200)["ok"] == true
      assert PortalState.conflict_email?("seed@example.com")
    end

    @tag :integration
    test "returns 400 when no email provided", %{conn: conn} do
      conn = post(conn, "/e2e/portal/conflicts", %{})
      assert json_response(conn, 400)["error"] =~ "email"
    end
  end

  # The /e2e/session route only compiles when E2E=1, and that build swaps the Repo
  # pool away from Ecto.Adapters.SQL.Sandbox, so `mix test` cannot drive it through
  # the router. The action is called directly instead — the route wiring itself is
  # exercised by the Playwright suite on every run.
  describe "create_session/2" do
    setup %{conn: conn} do
      %{
        conn: Plug.Test.init_test_session(conn, %{}),
        user: user_fixture(%{username: "e2e_admin"})
      }
    end

    test "mints a session for the default admin and lands in the BO", %{conn: conn, user: user} do
      conn = ZaqWeb.E2EController.create_session(conn, %{})

      assert redirected_to(conn) == "/bo/dashboard"
      assert get_session(conn, :user_id) == user.id
    end

    test "honours return_to so specs skip a second navigation", %{conn: conn, user: user} do
      conn = ZaqWeb.E2EController.create_session(conn, %{"return_to" => "/bo/people"})

      assert redirected_to(conn) == "/bo/people"
      assert get_session(conn, :user_id) == user.id
    end

    test "ignores a protocol-relative return_to", %{conn: conn} do
      conn = ZaqWeb.E2EController.create_session(conn, %{"return_to" => "//evil.example.com"})

      assert redirected_to(conn) == "/bo/dashboard"
    end

    test "ignores an absolute return_to", %{conn: conn} do
      conn =
        ZaqWeb.E2EController.create_session(conn, %{"return_to" => "https://evil.example.com"})

      assert redirected_to(conn) == "/bo/dashboard"
    end

    test "resolves an explicit username", %{conn: conn} do
      other = user_fixture(%{username: "someone_else"})

      conn = ZaqWeb.E2EController.create_session(conn, %{"username" => "someone_else"})

      assert redirected_to(conn) == "/bo/dashboard"
      assert get_session(conn, :user_id) == other.id
    end

    test "returns 404 for an unknown user rather than a silent login page", %{conn: conn} do
      conn = ZaqWeb.E2EController.create_session(conn, %{"username" => "nobody"})

      assert json_response(conn, 404)["error"] == "unknown_user"
      refute get_session(conn, :user_id)
    end
  end

  describe "GET /e2e/health" do
    test "returns 200 with correct shape", %{conn: conn} do
      conn = get(conn, "/e2e/health")

      assert json_response(conn, 200) == %{
               "status" => "ok",
               "env" => "test",
               "e2e" => true,
               "node" => Atom.to_string(node())
             }
    end
  end

  describe "GET /e2e/zaq-router-credential" do
    @tag :integration
    test "ensures and returns the ZAQ Router credential", %{conn: conn} do
      conn = get(conn, "/e2e/zaq-router-credential")
      body = json_response(conn, 200)

      assert body["found"] == true
      assert is_integer(body["id"])
      assert body["name"] == "ZAQ Router"
      assert body["provider"] == "zaq_router"
      assert body["has_api_key"] == false
    end

    @tag :integration
    test "can ensure a keyed ZAQ Router credential for model discovery", %{conn: conn} do
      conn = get(conn, "/e2e/zaq-router-credential?with_api_key=true")
      body = json_response(conn, 200)

      assert body["found"] == true
      assert is_integer(body["id"])
      assert body["name"] == "ZAQ Router"
      assert body["provider"] == "zaq_router"
      assert body["has_api_key"] == true
    end
  end

  describe "GET /e2e/telemetry/points" do
    test "returns 200 with correct shape", %{conn: conn} do
      conn = get(conn, "/e2e/telemetry/points")
      body = json_response(conn, 200)
      assert is_list(body["points"])
      assert is_integer(body["count"])
      assert Map.has_key?(body, "metric")
    end

    test "accepts metric and last_minutes params", %{conn: conn} do
      conn = get(conn, "/e2e/telemetry/points?metric=ingestion.*&limit=10&last_minutes=1")
      body = json_response(conn, 200)
      assert body["metric"] == "ingestion.*"
      assert is_list(body["points"])
    end
  end

  describe "GET /e2e/logs/recent" do
    test "returns 200 with correct shape", %{conn: conn} do
      conn = get(conn, "/e2e/logs/recent")
      body = json_response(conn, 200)
      assert is_list(body["logs"])
      assert is_integer(body["count"])
    end

    test "returns collected log entries filtered by level", %{conn: conn} do
      LogCollector.push(%{level: :error, message: "boom", timestamp: DateTime.utc_now()})
      LogCollector.push(%{level: :info, message: "not this one", timestamp: DateTime.utc_now()})

      conn = get(conn, "/e2e/logs/recent?level=error&limit=10")
      body = json_response(conn, 200)
      assert body["count"] == 1
      assert hd(body["logs"])["message"] == "boom"
    end

    test "returns all entries when no level filter", %{conn: conn} do
      LogCollector.push(%{level: :error, message: "err", timestamp: DateTime.utc_now()})
      LogCollector.push(%{level: :info, message: "inf", timestamp: DateTime.utc_now()})

      conn = get(conn, "/e2e/logs/recent")
      body = json_response(conn, 200)
      assert body["count"] == 2
    end
  end
end
