defmodule ZaqWeb.Components.DesignSystem.SwitchTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.Switch

  test "switch/1 inline boolean renders hidden false, knob, and check icon when on" do
    html =
      render_component(&Switch.switch/1,
        id: "sovereign",
        name: "ai_credential[sovereign]",
        label: "Sovereign credential",
        value: true
      )

    assert html =~ "type=\"checkbox\""
    assert html =~ "name=\"ai_credential[sovereign]\""
    assert html =~ "type=\"hidden\""
    assert html =~ "value=\"false\""
    assert html =~ "value=\"true\""
    assert html =~ "Sovereign credential"
    assert html =~ "zaq-switch-track"
    assert html =~ "zaq-switch-knob"
    assert html =~ "hero-check"
    assert html =~ "role=\"switch\""
    assert html =~ "checked"
    assert html =~ "aria-label=\"Sovereign credential\""
  end

  test "switch/1 unchecked keeps icon in DOM hidden via CSS" do
    html =
      render_component(&Switch.switch/1,
        id: "sovereign-off",
        name: "ai_credential[sovereign]",
        label: "Sovereign credential",
        value: false
      )

    assert html =~ "zaq-switch-knob"
    assert html =~ "zaq-switch-knob-icon"
    refute html =~ ~s( checked role="switch")
  end

  test "switch/1 setting_row layout renders title and description without inline label" do
    html =
      render_component(&Switch.switch/1,
        id: "capture-infra",
        name: "telemetry_config[capture_infra_metrics]",
        layout: :setting_row,
        label: "Capture infra metrics",
        description: "Collect Phoenix request, Repo query, and Oban runtime metrics.",
        value: false
      )

    assert html =~ "zaq-switch-setting-row"
    assert html =~ "Capture infra metrics"
    assert html =~ "Collect Phoenix request, Repo query, and Oban runtime metrics."
    assert html =~ "zaq-switch-track"
    refute html =~ "zaq-switch-text"
  end

  test "switch/1 enum mode uses hidden current value and checkbox without name" do
    html =
      render_component(&Switch.switch/1,
        id: "mcp-status",
        name: "mcp_endpoint[status]",
        mode: :enum,
        on_value: "enabled",
        off_value: "disabled",
        on_label: "Enabled",
        off_label: "Disabled",
        value: "enabled"
      )

    assert html =~ "name=\"mcp_endpoint[status]\""
    assert html =~ "value=\"enabled\""
    assert html =~ "Enabled"
    assert html =~ "hero-check"
    refute html =~ ~s(type="checkbox" id="mcp-status" name="mcp_endpoint[status]")
    assert html =~ ~s(type="checkbox" id="mcp-status")
  end

  test "switch/1 enum mode shows off label when value is disabled" do
    html =
      render_component(&Switch.switch/1,
        id: "mcp-status-off",
        name: "mcp_endpoint[status]",
        mode: :enum,
        on_value: "enabled",
        off_value: "disabled",
        on_label: "Enabled",
        off_label: "Disabled",
        value: "disabled"
      )

    assert html =~ "Disabled"
    assert html =~ "value=\"disabled\""
    refute html =~ ~s( checked role="switch")
  end

  test "switch/1 with form field derives checked state" do
    form = Phoenix.Component.to_form(%{"sovereign" => "true"}, as: :ai_credential)

    html =
      render_component(&Switch.switch/1,
        field: form[:sovereign],
        label: "Sovereign credential"
      )

    assert html =~ "name=\"ai_credential[sovereign]\""
    assert html =~ "Sovereign credential"
    assert html =~ "checked"
    assert html =~ "hero-check"
  end

  test "switch/1 renders validation errors" do
    html =
      render_component(&Switch.switch/1,
        id: "sovereign-error",
        name: "ai_credential[sovereign]",
        label: "Sovereign credential",
        value: false,
        errors: ["must be accepted for this region"]
      )

    assert html =~ "must be accepted for this region"
  end
end
