defmodule Zaq.E2EPw.BONavigationTest do
  # Port of test/e2e/support/bo-navigation.test.cjs for the suite's own `goto_back_office_live`.
  # The spec loops over the three browsers and CI picks the leg's; here the module runs on the
  # leg's browser. It never reaches the server, so it runs alongside the journeys.
  use Zaq.E2EPw.Case, async: true

  import Zaq.E2EPw.BO

  alias Playwright.{Clock, Request, Route}

  @phoenix_js Path.expand("../../deps/phoenix/priv/static/phoenix.js", __DIR__)
  @live_view_js Path.expand(
                  "../../deps/phoenix_live_view/priv/static/phoenix_live_view.js",
                  __DIR__
                )

  @tag timeout: 20_000
  test "full-page navigation cancels the outgoing LiveView recovery reload", %{page: page} do
    # originalRequests and recoveryReloads, counted from the route handler and the binding.
    counts = :counters.new(2, [])
    original_requests = 1
    recovery_reloads = 2
    clock = Page.clock(page)

    Page.expose_function!(page, "recordRecoveryReload", fn ->
      :counters.add(counts, recovery_reloads, 1)
    end)

    Page.route!(page, "http://navigation.test/**", fn route ->
      case route |> Route.request() |> Request.url() |> URI.parse() do
        %URI{path: "/original"} -> :counters.add(counts, original_requests, 1)
        _ -> :ok
      end

      Route.fulfill!(route,
        content_type: "text/html",
        body:
          ~s|<div data-phx-main class="phx-connected">Ready</div><script>window.liveSocket = {isConnected: () => true}</script>|
      )
    end)

    Clock.install!(clock, time: ~U[2026-01-01 00:00:00Z])
    Clock.pause_at!(clock, ~U[2026-01-01 01:00:00Z])
    Page.goto!(page, "http://navigation.test/original")
    Page.add_script_tag!(page, path: @phoenix_js)
    Page.add_script_tag!(page, path: @live_view_js)

    Page.evaluate!(page, """
    () => {
      window.liveSocket = new window.LiveView.LiveSocket('/live', window.Phoenix.Socket, {
        reloadJitterMin: 1000,
        reloadJitterMax: 1000,
      })
      // Use LiveView's real recovery timer rather than mocking disconnect.
      window.liveSocket.reloadWithJitter({
        isDestroyed: () => false,
        isConnected: () => false,
        destroy: () => window.recordRecoveryReload(),
      })
    }
    """)

    goto = fn page, url ->
      # Advance the outgoing document's clock at the navigation boundary.
      Clock.run_for!(clock, 1001)
      Page.goto!(page, url)
    end

    goto_back_office_live(page, "http://navigation.test/destination", goto: goto)

    assert :counters.get(counts, recovery_reloads) == 0,
           "the outgoing recovery timer must be cancelled"

    assert :counters.get(counts, original_requests) == 1, "the outgoing document must not reload"
    assert Page.url(page) == "http://navigation.test/destination"
    assert page |> Page.locator("[data-phx-main]") |> Locator.text_content!() == "Ready"
  end

  @tag timeout: 20_000
  test "chromium: navigation works without LiveView and preserves navigation errors", %{
    page: page,
    browser_name: browser_name
  } do
    # The spec runs this on chromium only.
    if browser_name == :chromium do
      Page.route!(page, "http://navigation.test/plain", &Route.fulfill!(&1, body: "Plain page"))
      goto_back_office_live(page, "http://navigation.test/plain", ensure_connected: false)
      assert page |> Page.locator("body") |> Locator.text_content!() == "Plain page"
      Page.route!(page, "http://navigation.test/failure", &Route.abort!(&1, "failed"))

      assert_raise Playwright.PlaywrightError, fn ->
        goto_back_office_live(page, "http://navigation.test/failure", ensure_connected: false)
      end
    end
  end
end
