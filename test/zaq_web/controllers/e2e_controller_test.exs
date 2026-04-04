defmodule ZaqWeb.E2EControllerTest do
  use ZaqWeb.ConnCase, async: false

  alias Zaq.E2E.LogCollector

  setup do
    LogCollector.clear()
    :ok
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
