defmodule Zaq.Engine.Telemetry.Workers.PushRollupsWorkerTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.BenchmarkConnector.HTTP
  alias Zaq.Engine.Telemetry.Rollup
  alias Zaq.Engine.Telemetry.Workers.PushRollupsWorker
  alias Zaq.Repo
  alias Zaq.System

  setup do
    Repo.delete_all(Rollup)

    original = Application.get_env(:zaq, Telemetry, [])

    Application.put_env(
      :zaq,
      Telemetry,
      Keyword.merge(original, req_options: [plug: {Req.Test, HTTP}])
    )

    on_exit(fn -> Application.put_env(:zaq, Telemetry, original) end)

    :ok
  end

  test "perform/1 pushes local rollups and updates push cursor" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    insert_rollup(now)

    assert {:ok, _} = System.set_config("telemetry.enabled", "true")
    assert {:ok, _} = System.set_config("telemetry.benchmark_opt_in", "true")

    Req.Test.stub(HTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/telemetry/rollups"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert is_map(decoded["org"])
      assert length(decoded["rollups"]) == 1

      Req.Test.json(conn, %{"ok" => true})
    end)

    assert :ok = PushRollupsWorker.perform(%{})
    assert %DateTime{} = Telemetry.get_cursor("telemetry.push_cursor")
  end

  test "perform/1 is a no-op when benchmark opt-in is disabled" do
    assert {:ok, _} = System.set_config("telemetry.enabled", "true")
    assert {:ok, _} = System.set_config("telemetry.benchmark_opt_in", "false")

    Req.Test.stub(HTTP, fn _conn ->
      flunk("remote API should not be called when benchmark opt-in is disabled")
    end)

    assert :ok = PushRollupsWorker.perform(%{})
  end

  defp insert_rollup(updated_at) do
    Repo.insert!(%Rollup{
      metric_key: "qa.answer.latency_ms",
      bucket_start: DateTime.add(updated_at, -600, :second),
      bucket_size: "10m",
      source: "local",
      dimensions: %{},
      dimension_key: "global",
      value_sum: 300.0,
      value_count: 2,
      value_min: 120.0,
      value_max: 180.0,
      last_value: 180.0,
      last_at: updated_at,
      inserted_at: updated_at,
      updated_at: updated_at
    })
  end
end
