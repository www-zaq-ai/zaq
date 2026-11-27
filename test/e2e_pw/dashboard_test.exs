defmodule Zaq.E2EPw.DashboardTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  # BO Dashboard
  setup_all %{browser: browser} do
    request = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))

    reset_e2e_state(request)
    APIRequestContext.dispose!(request)
    :ok
  end

  defp expect_href(page, selector, href) do
    page |> Page.locator(selector) |> Expect.to_have_attribute!("href", href)
  end

  test "KPI metric links, cards, and sub-metric CTAs", %{page: page, request: request} do
    reset_e2e_state(request)
    login_to_back_office(page)
    goto_back_office_live(page, "/bo/dashboard")

    expect_href(page, "#dashboard-metric-documents-ingested", "/bo/ingestion")

    page
    |> Page.locator("#dashboard-metric-documents-ingested")
    |> Expect.to_contain_text!("Documents ingested")

    page |> Page.locator("#dashboard-metric-documents-ingested-card") |> Expect.to_be_visible!()

    page
    |> Page.locator("#dashboard-metric-documents-ingested")
    |> Expect.to_contain_text!("range: 30d")

    expect_href(page, "#dashboard-metric-llm-api-calls", "/bo/ai-diagnostics")

    page
    |> Page.locator("#dashboard-metric-llm-api-calls")
    |> Expect.to_contain_text!("LLM API calls")

    expect_href(page, "#dashboard-metric-qa-response-time", "/bo/chat")
    page |> Page.locator("#dashboard-metric-qa-response-time-card") |> Expect.to_be_visible!()

    expect_href(
      page,
      "#dashboard-knowledge-base-metrics-link",
      "/bo/dashboard/knowledge-base-metrics"
    )

    expect_href(page, "#dashboard-llm-performance-link", "/bo/dashboard/llm-performance")

    expect_href(
      page,
      "#dashboard-conversations-metrics-link",
      "/bo/dashboard/conversations-metrics"
    )
  end

  test "services table lists core services with a status pill", %{page: page, request: request} do
    reset_e2e_state(request)
    login_to_back_office(page)
    goto_back_office_live(page, "/bo/dashboard")

    page |> Page.get_by_text("Services", exact: true) |> Expect.to_be_visible!()

    for name <- ["Engine", "Agent", "Ingestion", "Channels", "Back Office"] do
      page
      |> Page.locator("tbody tr")
      |> Locator.filter(has_text: name)
      |> Expect.to_have_count!(1)
    end

    page |> Page.locator("tbody tr") |> Expect.to_have_count!(5)

    statuses = page |> Page.locator("tbody tr td:last-child") |> Locator.all_text_contents!()
    assert Enum.all?(statuses, &(String.trim(&1) =~ ~r/Running|Disabled/))

    page
    |> Page.locator("tbody tr")
    |> Locator.filter(has_text: "Back Office")
    |> Expect.to_contain_text!("Running")
  end

  test "add-ons empty state", %{page: page, request: request} do
    reset_e2e_state(request)
    login_to_back_office(page)
    goto_back_office_live(page, "/bo/dashboard")
    wait_for_live_view_settled(page)

    addons = Page.get_by_test_id(page, "dashboard-addons-section")
    addons |> Locator.get_by_text("Add-ons", exact: true) |> Expect.to_be_visible!()
    addons |> Locator.get_by_text("No Add-ons") |> Expect.to_be_visible!()
    addons |> Locator.get_by_text("Running in basic mode") |> Expect.to_be_visible!()
    empty_cta = Locator.get_by_test_id(addons, "addon-upsell-cta")
    Expect.to_be_visible!(empty_cta)
    Expect.to_have_text!(empty_cta, "View Add-ons")
    Expect.to_have_attribute!(empty_cta, "href", "/bo/addons")
  end

  test "add-ons loaded state", %{page: page, request: request} do
    reset_e2e_state(request)

    future = DateTime.utc_now() |> DateTime.add(45 * 86_400, :second) |> DateTime.to_iso8601()

    create_e2e_addon_package(request, %{
      company_name: "E2E Addon Co",
      license_key: "lic-e2e-dashboard",
      expires_at: future,
      features: [%{name: "ontology"}, %{name: "reports"}]
    })

    login_to_back_office(page)
    goto_back_office_live(page, "/bo/dashboard")

    page |> Page.get_by_text("E2E Addon Co") |> Expect.to_be_visible!()
    page |> Page.get_by_text("lic-e2e-dashboard") |> Expect.to_be_visible!()

    loaded_cta = Page.get_by_test_id(page, "addon-summary-cta")
    Expect.to_be_visible!(loaded_cta)
    Expect.to_have_text!(loaded_cta, "View Add-ons")
    Expect.to_have_attribute!(loaded_cta, "href", "/bo/addons")
  end
end
