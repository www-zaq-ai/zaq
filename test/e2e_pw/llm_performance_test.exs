defmodule Zaq.E2EPw.LlmPerformanceTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  # BO LLM performance
  setup %{request: request} do
    reset_e2e_state(request)
    seed_e2e_llm_performance(request)
    :ok
  end

  # compareDocumentPosition(...) & DOCUMENT_POSITION_FOLLOWING
  defp precedes?(locator, selector) do
    Locator.evaluate!(
      locator,
      """
      (node, selector) => (node.compareDocumentPosition(document.querySelector(selector)) &
        Node.DOCUMENT_POSITION_FOLLOWING) !== 0
      """,
      selector
    )
  end

  test "refreshes ranges and keeps retrieval effectiveness below global charts", %{page: page} do
    login_to_back_office(page)
    goto_back_office_live(page, "/bo/dashboard/llm-performance")

    api_calls = Page.locator(page, "#llm-performance-api-calls-chart")
    retrieval = Page.locator(page, "#llm-performance-retrieval-effectiveness")
    rankings = Page.locator(page, "#llm-performance-rankings")

    Expect.to_be_visible!(api_calls)
    Expect.to_be_visible!(retrieval)
    Expect.to_be_visible!(rankings)
    assert precedes?(api_calls, "#llm-performance-retrieval-effectiveness") == true
    assert precedes?(retrieval, "#llm-performance-rankings") == true

    page |> Page.locator("#llm-performance-range-24h") |> Locator.click!()
    wait_for_live_view_settled(page)
    page |> Page.locator("#llm-performance-selected-range") |> Expect.to_have_text!("24h")

    page
    |> Page.locator("#llm-performance-range-24h")
    |> Expect.to_have_attribute!("data-active", "true")

    page |> Page.locator("#llm-performance-range-30d") |> Locator.click!()
    wait_for_live_view_settled(page)
    page |> Page.locator("#llm-performance-selected-range") |> Expect.to_have_text!("30d")
  end

  test "sorting changes model and people top-five membership", %{page: page} do
    login_to_back_office(page)
    goto_back_office_live(page, "/bo/dashboard/llm-performance")

    models = Page.locator(page, "#llm-top-models-table")
    people = Page.locator(page, "#llm-top-people-table")

    Expect.to_contain_text!(models, "e2e-alpha")
    models |> Expect.not_() |> Expect.to_contain_text!("e2e-foxtrot")
    Expect.to_contain_text!(people, "Ada Lovelace")
    people |> Expect.not_() |> Expect.to_contain_text!("Mary Jackson")

    page |> Page.locator("#llm-model-sort-calls") |> Locator.click!()
    page |> Page.locator("#llm-people-sort-calls") |> Locator.click!()
    wait_for_live_view_settled(page)

    Expect.to_contain_text!(models, "e2e-foxtrot")
    models |> Expect.not_() |> Expect.to_contain_text!("e2e-alpha")
    Expect.to_contain_text!(people, "Mary Jackson")
    people |> Expect.not_() |> Expect.to_contain_text!("Ada Lovelace")
  end

  test "agent selection filters lower charts without changing global charts", %{page: page} do
    login_to_back_office(page)
    goto_back_office_live(page, "/bo/dashboard/llm-performance")

    global_calls = Page.locator(page, "#llm-performance-api-calls-chart")
    global_tokens = Page.locator(page, "#llm-performance-token-usage-chart")
    calls_before = Locator.text_content!(global_calls)
    tokens_before = Locator.text_content!(global_tokens)

    page |> Page.locator("#llm-agent-select [data-select-trigger]") |> Locator.click!()

    page
    |> Page.locator(~s|#llm-agent-select [data-select-option="Support Agent"]|)
    |> Locator.click!()

    wait_for_live_view_settled(page)

    page |> Page.locator("#llm-performance-agent-api-calls-chart") |> Expect.to_be_visible!()
    page |> Page.locator("#llm-performance-agent-token-usage-chart") |> Expect.to_be_visible!()
    Expect.to_have_text!(global_calls, calls_before)
    Expect.to_have_text!(global_tokens, tokens_before)
  end

  test "renders safe empty states when attributed telemetry is unavailable", %{
    page: page,
    request: request
  } do
    seed_e2e_llm_performance(request, "clear")
    login_to_back_office(page)
    goto_back_office_live(page, "/bo/dashboard/llm-performance")

    page
    |> Page.locator("#llm-top-models-table")
    |> Expect.to_contain_text!("No attributed usage in this range.")

    page
    |> Page.locator("#llm-top-people-table")
    |> Expect.to_contain_text!("No attributed usage in this range.")

    page
    |> Page.locator("#llm-agent-empty")
    |> Expect.to_contain_text!("Select an agent to view its usage.")

    page |> Page.locator("#llm-performance-api-calls-chart") |> Expect.to_be_visible!()
    page |> Page.locator("#llm-performance-token-usage-chart") |> Expect.to_be_visible!()
  end
end
