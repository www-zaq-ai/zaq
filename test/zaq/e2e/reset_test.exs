defmodule Zaq.E2E.ResetTest do
  use Zaq.DataCase, async: false

  alias Zaq.E2E.Reset
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.{Buffer, Rollup}
  alias Zaq.Engine.Telemetry.Workers.AggregateRollupsWorker
  alias Zaq.System

  test "reset preserves aggregation progress while retaining raw telemetry" do
    Telemetry.record("qa.llm.call.count", 1, %{"model" => "e2e-fake"})
    :ok = Buffer.flush()
    :ok = AggregateRollupsWorker.perform(%Oban.Job{})
    cursor = Telemetry.get_cursor_id("telemetry.rollup_point_id_cursor")
    assert cursor > 0
    rollups = Repo.all(Rollup)

    Reset.reset_system_config!()

    assert Telemetry.get_cursor_id("telemetry.rollup_point_id_cursor") == cursor
    :ok = AggregateRollupsWorker.perform(%Oban.Job{})
    assert Repo.all(Rollup) == rollups
  end

  test "reset removes AI credentials and their Connect credentials and grants" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "ZAQ Router",
               provider: "zaq_router",
               endpoint: "http://localhost:4002/e2e/llm/v1",
               api_key: "e2e-zaq-router-key"
             })

    connect_credential_id = credential.connect_credential_id

    assert [%{credential_id: ^connect_credential_id}] =
             Connect.list_grant_summaries(credential_id: connect_credential_id)

    assert %{} = Reset.reset_system_config!()
    assert System.get_ai_provider_credential_by_name("ZAQ Router") == nil
    assert Connect.fetch_credential(connect_credential_id) == {:error, :not_found}
    assert Connect.list_grant_summaries(credential_id: connect_credential_id) == []

    assert {:ok, recreated} =
             System.create_ai_provider_credential(%{
               name: "ZAQ Router",
               provider: "zaq_router",
               endpoint: "http://localhost:4002/e2e/llm/v1",
               api_key: "e2e-zaq-router-key"
             })

    refute recreated.connect_credential_id == connect_credential_id
  end
end
