defmodule ZaqWeb.Dashboard.ExtensionHealthTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Zaq.Engine.Extension.Health
  alias ZaqWeb.Dashboard.ExtensionHealth

  property "shows the response time in milliseconds beside the last-check time, including zero" do
    check all(response_time_ms <- integer(0..60_000)) do
      html =
        render_component(&ExtensionHealth.extension_health/1,
          health: %Health{
            status: :healthy,
            checked_at: ~U[2026-11-14 08:00:00Z],
            response_time_ms: response_time_ms
          }
        )

      text =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("p:has(time)")
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      assert text == "Last checked: 08:00:00 UTC · #{response_time_ms} ms"
    end
  end

  test "omits response time when a check has no response or has not run" do
    for status <- [:unconfigured, :checking, :unreachable, :error] do
      checked_at = if status in [:unreachable, :error], do: ~U[2026-11-14 08:00:00Z]

      html =
        render_component(&ExtensionHealth.extension_health/1,
          health: %Health{status: status, checked_at: checked_at}
        )

      refute html =~ " ms"
      assert html =~ "Last checked:" == not is_nil(checked_at)
    end
  end

  test "renders all connectivity states without implying entitlement" do
    for {status, label} <- [
          unconfigured: "Unconfigured",
          checking: "Checking",
          healthy: "Healthy",
          unreachable: "Unreachable",
          error: "Error"
        ] do
      html =
        render_component(&ExtensionHealth.extension_health/1, health: %Health{status: status})

      assert html =~ "Extension gateway"
      assert html =~ label
      assert html =~ "Add-on access is unchanged"
      refute html =~ "Licensed"
    end
  end

  test "shows last-check time but never renders raw failure details" do
    checked_at = ~U[2026-11-14 08:00:00Z]

    html =
      render_component(&ExtensionHealth.extension_health/1,
        health: %Health{status: :error, reason: :tls_error, checked_at: checked_at}
      )

    assert html =~ DateTime.to_iso8601(checked_at)
    assert html =~ "certificates"
    refute html =~ "tls_error"
  end
end
