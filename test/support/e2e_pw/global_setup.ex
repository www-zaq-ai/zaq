defmodule Zaq.E2EPw.GlobalSetup do
  @moduledoc """
  Port of `test/e2e/support/global-setup.js`, run once by `test/test_helper.exs` before the
  browser suite:

    1. verifies the compiled assets are served and the server booted with `E2E=1`;
    2. logs the admin in through the form and saves the storage state that every test's
       context starts from (`config :playwright, :test, storage_state: ...`).

  Everything needed for per-test isolation (DB reset, processor state) is owned by the tests
  via `POST /e2e/reset`.
  """

  alias Playwright.{APIRequest, APIRequestContext, APIResponse}
  alias Playwright.{Browser, BrowserContext, BrowserType, Locator, Page}

  @required_asset_paths ["/assets/js/app.js", "/assets/css/app.css"]

  def run do
    # A driver of its own, stopped before the suite's: the tests' drivers start with the pool.
    {:ok, supervisor} = Playwright.Supervisor.start_link(name: __MODULE__)

    try do
      playwright = Playwright.instance(__MODULE__)
      check_server(playwright)
      log_in(playwright)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp base_url, do: System.get_env("E2E_BASE_URL") || "http://localhost:4002"
  defp admin_username, do: System.get_env("E2E_ADMIN_USERNAME") || "e2e_admin"
  defp admin_password, do: System.get_env("E2E_ADMIN_PASSWORD") || "StrongPass1!"

  defp auth_browser_type(playwright) do
    case System.get_env("E2E_AUTH_BROWSER") || "chromium" do
      "chromium" -> Playwright.chromium(playwright)
      "firefox" -> Playwright.firefox(playwright)
      "webkit" -> Playwright.webkit(playwright)
      other -> raise "Unsupported E2E_AUTH_BROWSER=#{other}"
    end
  end

  defp check_server(playwright) do
    ctx = APIRequest.new_context!(Playwright.request(playwright), base_url: base_url())

    for path <- @required_asset_paths do
      res = APIRequestContext.get!(ctx, path)

      unless APIResponse.ok(res) do
        raise "Missing required asset #{path} (status #{APIResponse.status(res)}). " <>
                ~s|Run "mix assets.setup && mix assets.build" before E2E.|
      end
    end

    health = APIRequestContext.get!(ctx, "/e2e/health")

    unless APIResponse.ok(health) do
      raise "/e2e/health returned #{APIResponse.status(health)}. Server must boot with E2E=1."
    end

    APIRequestContext.dispose!(ctx)
  end

  defp log_in(playwright) do
    browser = playwright |> auth_browser_type() |> BrowserType.launch!()

    try do
      page = Browser.new_page!(browser, base_url: base_url())

      Page.goto!(page, "/bo/login")
      Page.wait_for_selector!(page, "[data-phx-main].phx-connected", timeout: 15_000)
      page |> Page.locator(~s|input[name="username"]|) |> Locator.fill!(admin_username())
      page |> Page.locator(~s|input[name="password"]|) |> Locator.fill!(admin_password())
      page |> Page.get_by_role(:button, name: "Sign In to Dashboard") |> Locator.click!()
      Page.wait_for_url!(page, ~r{/bo/(dashboard|change-password)}, timeout: 15_000)

      auth_state_path = Playwright.Test.config()[:storage_state]
      File.mkdir_p!(Path.dirname(auth_state_path))
      page |> Page.context() |> BrowserContext.storage_state!(path: auth_state_path)
    after
      Browser.close!(browser)
    end
  end
end
