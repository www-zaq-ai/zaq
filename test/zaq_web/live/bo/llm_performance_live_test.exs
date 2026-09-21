defmodule ZaqWeb.Live.BO.LLMPerformanceLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Rollup
  alias Zaq.Repo

  setup %{conn: conn} do
    user = user_fixture(%{username: "llm_perf_admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "renders llm performance charts", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/bo/dashboard/llm-performance")

    assert has_element?(view, "#llm-performance-page")
    assert has_element?(view, "#llm-performance-selected-range", "7d")
    assert has_element?(view, "#llm-performance-range-7d[data-active='true']")
    assert has_element?(view, "#llm-performance-api-calls-chart")
    assert has_element?(view, "#llm-performance-token-usage-chart")
    assert has_element?(view, "#llm-performance-retrieval-effectiveness")
    assert has_element?(view, "#llm-top-models-table")
    assert has_element?(view, "#llm-top-people-table")
    assert has_element?(view, "#llm-agent-select")
    assert has_element?(view, "#llm-agent-empty", "Select an agent to view its usage.")
    assert has_element?(view, "#llm-performance-back-to-dashboard[href='/bo/dashboard']")

    assert element_position(html, "llm-performance-api-calls-chart") <
             element_position(html, "llm-performance-retrieval-effectiveness")

    assert element_position(html, "llm-performance-retrieval-effectiveness") <
             element_position(html, "llm-performance-rankings")
  end

  test "set_range updates selected range", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/llm-performance")

    view
    |> element("#llm-performance-range-30d")
    |> render_click()

    assert has_element?(view, "#llm-performance-selected-range", "30d")
    assert has_element?(view, "#llm-performance-range-30d[data-active='true']")
  end

  test "all valid ranges can be selected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/llm-performance")

    for range <- ["24h", "7d", "30d", "90d"] do
      view
      |> element("#llm-performance-range-#{range}")
      |> render_click()

      assert has_element?(view, "#llm-performance-selected-range", range)
      assert has_element?(view, "#llm-performance-range-#{range}[data-active='true']")
    end
  end

  test "invalid range keeps current selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/llm-performance")

    render_click(view, "set_range", %{"range" => "invalid"})

    assert has_element?(view, "#llm-performance-selected-range", "7d")
    assert has_element?(view, "#llm-performance-range-7d[data-active='true']")
  end

  test "refresh telemetry info keeps page render stable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/llm-performance")

    send(view.pid, :refresh_telemetry)

    assert has_element?(view, "#llm-performance-page")
    assert has_element?(view, "#llm-performance-api-calls-chart")
    assert has_element?(view, "#llm-performance-token-usage-chart")
    assert has_element?(view, "#llm-performance-retrieval-effectiveness")
  end

  test "ranking sorts persist across range changes and refreshes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/llm-performance")

    view |> element("#llm-model-sort-calls") |> render_click()
    view |> element("#llm-people-sort-calls") |> render_click()
    view |> element("#llm-performance-range-30d") |> render_click()
    send(view.pid, :refresh_telemetry)

    assert has_element?(view, "#llm-model-sort-calls.zaq-btn-secondary--active")
    assert has_element?(view, "#llm-people-sort-calls.zaq-btn-secondary--active")
    assert has_element?(view, "#llm-performance-selected-range", "30d")
  end

  test "agent selection renders filtered charts without replacing global charts", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    dimensions = %{
      "configured_agent_id" => 10,
      "configured_agent_name" => "Support Agent",
      "llm_provider" => "openai",
      "model" => "gpt-4.1-mini"
    }

    insert_rollup("qa.llm.call.count", now, 2.0, dimensions)
    insert_rollup("qa.llm.tokens.prompt", now, 20.0, dimensions)
    insert_rollup("qa.llm.tokens.completion", now, 10.0, dimensions)

    {:ok, view, _html} = live(conn, ~p"/bo/dashboard/llm-performance")

    render_change(view, "select_agent", %{"agent_id" => "10"})

    assert has_element?(view, "#llm-performance-api-calls-chart")
    assert has_element?(view, "#llm-performance-token-usage-chart")
    assert has_element?(view, "#llm-performance-agent-api-calls-chart")
    assert has_element?(view, "#llm-performance-agent-token-usage-chart")
    refute has_element?(view, "#llm-agent-empty")
  end

  defp insert_rollup(metric_key, bucket_start, sum, dimensions) do
    Repo.insert!(%Rollup{
      metric_key: metric_key,
      bucket_start: bucket_start,
      bucket_size: "10m",
      source: "local",
      dimensions: dimensions,
      dimension_key: Telemetry.dimension_key(dimensions),
      value_sum: sum,
      value_count: 1,
      value_min: sum,
      value_max: sum,
      last_value: sum,
      last_at: bucket_start
    })
  end

  defp element_position(html, id) do
    {position, _length} = :binary.match(html, ~s(id="#{id}"))
    position
  end
end
