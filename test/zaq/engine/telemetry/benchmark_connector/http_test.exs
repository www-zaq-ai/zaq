defmodule Zaq.Engine.Telemetry.BenchmarkConnector.HTTPTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.BenchmarkConnector.HTTP

  setup do
    original = Application.get_env(:zaq, Telemetry, [])

    Application.put_env(
      :zaq,
      Telemetry,
      Keyword.merge(original, req_options: [plug: {Req.Test, HTTP}])
    )

    on_exit(fn -> Application.put_env(:zaq, Telemetry, original) end)

    :ok
  end

  test "push_rollups/1 returns :ok on 2xx response" do
    Req.Test.stub(HTTP, fn conn ->
      assert conn.request_path == "/api/v1/telemetry/rollups"
      assert conn.method == "POST"
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert :ok = HTTP.push_rollups(%{"rollups" => []})
  end

  test "pull_rollups/1 returns decoded body on 2xx response" do
    Req.Test.stub(HTTP, fn conn ->
      assert conn.request_path == "/api/v1/telemetry/benchmarks"
      Req.Test.json(conn, %{"rollups" => []})
    end)

    assert {:ok, %{"rollups" => []}} = HTTP.pull_rollups(%{"since" => nil})
  end

  test "returns remote error tuple for non-2xx response" do
    Req.Test.stub(HTTP, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"error" => "invalid"})
    end)

    assert {:error, {:remote_error, 422, %{"error" => "invalid"}}} =
             HTTP.pull_rollups(%{"since" => nil})
  end

  test "includes bearer token when configured in env" do
    previous = Elixir.System.get_env("TELEMETRY_REMOTE_TOKEN")
    Elixir.System.put_env("TELEMETRY_REMOTE_TOKEN", "secret-token")

    on_exit(fn ->
      if previous do
        Elixir.System.put_env("TELEMETRY_REMOTE_TOKEN", previous)
      else
        Elixir.System.delete_env("TELEMETRY_REMOTE_TOKEN")
      end
    end)

    Req.Test.stub(HTTP, fn conn ->
      assert ["Bearer secret-token"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert :ok = HTTP.push_rollups(%{"rollups" => []})
  end
end
