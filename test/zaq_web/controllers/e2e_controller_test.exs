defmodule ZaqWeb.E2EControllerTest do
  use ZaqWeb.ConnCase, async: false

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
