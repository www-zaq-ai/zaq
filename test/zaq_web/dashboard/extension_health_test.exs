defmodule ZaqWeb.Dashboard.ExtensionHealthTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Zaq.Engine.Extension.Health
  alias ZaqWeb.Dashboard.ExtensionHealth

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
