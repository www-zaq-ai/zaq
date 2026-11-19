defmodule Zaq.E2EPw.VersionBadgeTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  # Version update badge
  setup_all %{browser: browser} do
    # test.beforeAll: a request context of its own, outside any test.
    request = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))

    reset_e2e_state(request)
    APIRequestContext.dispose!(request)
    :ok
  end

  test "shows version and update badge with correct link attributes when enabled", %{
    page: page,
    request: request
  } do
    reset_e2e_state(request)
    set_e2e_system_config(request, "ui.update_badge_enabled", "true")

    login_to_back_office(page)

    enabled_version_text = page |> Page.locator(".sidebar-version") |> Locator.text_content!()
    assert String.trim(enabled_version_text || "") =~ ~r/^v\S+$/

    badge_link = Page.locator(page, "#sidebar-version-update-badge")
    Expect.to_be_visible!(badge_link)
    Expect.to_have_attribute!(badge_link, "href", "https://github.com/www-zaq-ai/zaq/releases")
    Expect.to_have_attribute!(badge_link, "target", "_blank")
    Expect.to_have_attribute!(badge_link, "rel", "noopener noreferrer")
  end

  test "shows version and hides update badge when disabled", %{page: page, request: request} do
    reset_e2e_state(request)
    set_e2e_system_config(request, "ui.update_badge_enabled", "false")

    login_to_back_office(page)

    disabled_version_text = page |> Page.locator(".sidebar-version") |> Locator.text_content!()
    assert String.trim(disabled_version_text || "") =~ ~r/^v\S+$/
    page |> Page.locator("#sidebar-version-update-badge") |> Expect.to_have_count!(0)
  end
end
