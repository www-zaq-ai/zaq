defmodule Zaq.E2EPw.OntologyFeatureGateTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  # Ontology feature gate
  setup_all %{browser: browser} do
    request = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))

    reset_e2e_state(request)
    APIRequestContext.dispose!(request)
    :ok
  end

  test "shows add-on upsell when ontology feature is not loaded", %{page: page, request: request} do
    reset_e2e_state(request)
    login_to_back_office(page)
    goto_back_office_live(page, "/bo/ontology")

    page |> Page.get_by_text("Feature Not Enabled") |> Expect.to_be_visible!()
    page |> Page.get_by_text(~r/ontology feature is not enabled/i) |> Expect.to_be_visible!()

    cta = Page.get_by_test_id(page, "addon-upsell-cta")
    Expect.to_be_visible!(cta)
    Expect.to_have_text!(cta, "View Add-ons")
    Expect.to_have_attribute!(cta, "href", "/bo/addons")
  end
end
