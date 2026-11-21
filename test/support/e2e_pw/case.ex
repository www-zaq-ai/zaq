defmodule Zaq.E2EPw.Case do
  @moduledoc """
  Case template for the browser journeys in `test/e2e_pw`.

  `Playwright.Case` gives each test a `context` and `page` of the configured device, starting
  from the admin's storage state (`config/test.exs`, saved by `test/test_helper.exs`), and the
  template adds Playwright Test's `request` fixture: an API request context of its own, with
  the same storage state. The project, and so the device and browser, comes from
  `E2E_AUTH_BROWSER` (chromium, firefox or webkit): `project/0`.

  The journeys share one server and database (`POST /e2e/reset`), so modules are not async.
  """

  use ExUnit.CaseTemplate

  alias Playwright.Test.BrowserPool

  @devices %{
    "chromium" => "Desktop Chrome",
    "firefox" => "Desktop Firefox",
    "webkit" => "Desktop Safari"
  }

  @doc "The config's project of `E2E_AUTH_BROWSER` (one per CI leg): `journeys-<browser>`."
  def project do
    browser = System.get_env("E2E_AUTH_BROWSER", "chromium")
    device = Map.get(@devices, browser) || raise "Unsupported E2E_AUTH_BROWSER=#{browser}"
    Playwright.Test.parameters([name: "journeys-#{browser}"] ++ Playwright.device(device))
  end

  using opts do
    opts = Keyword.put_new(opts, :parameterize, quote(do: [Zaq.E2EPw.Case.project()]))

    quote do
      use Playwright.Case, unquote(opts)

      alias Playwright.{APIRequest, APIRequestContext, APIResponse}

      @moduletag :e2e

      setup %{browser: browser} do
        playwright = BrowserPool.playwright(browser)
        %{request: APIRequest.new_context!(Playwright.request(playwright))}
      end
    end
  end
end
