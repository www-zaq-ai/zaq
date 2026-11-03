defmodule ZaqWeb.Live.BO.System.SystemConfig.GlobalTabTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Live.BO.System.SystemConfig.GlobalTab

  test "panel renders None when the former built-in global default is unset" do
    html =
      render_component(&GlobalTab.panel/1,
        global_agent_options: [],
        global_default_agent_id: nil,
        global_base_url: "",
        global_language: "en",
        global_timezone: nil,
        detected_timezone: nil
      )

    assert html =~ "Global"
    assert html =~ "Global Base URL"
    assert html =~ "Global Default Agent"
    refute html =~ "Default Zaq Agent"
    assert html =~ ~s(id="global-base-url-input")
    assert html =~ ~s(phx-submit="save_global_base_url")
    assert html =~ ~s(id="global-default-agent-select")
    assert html =~ ~s(phx-submit="save_global_default_agent")
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#global-default-agent-select input[data-select-value]"),
             "value"
           ) == [""]

    assert LazyHTML.text(
             LazyHTML.query(document, "#global-default-agent-select [data-select-label]")
           ) =~ "None"

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#global-language-select li[data-select-value='fr']"),
             "data-select-disabled"
           ) == ["true"]

    assert Enum.empty?(LazyHTML.query(document, "select, input[data-select-search]"))
  end

  test "panel selects configured global default agent" do
    html =
      render_component(&GlobalTab.panel/1,
        global_agent_options: [{"Answering", 1}, {"Escalation", 2}],
        global_default_agent_id: 2,
        global_base_url: "https://zaq.example",
        global_language: "en",
        global_timezone: nil,
        detected_timezone: nil
      )

    assert html =~ "Answering"
    assert html =~ "Escalation"
    assert html =~ ~s(value="https://zaq.example")
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.attribute(
             LazyHTML.query(document, "#global-default-agent-select input[data-select-value]"),
             "value"
           ) == ["2"]

    assert LazyHTML.text(
             LazyHTML.query(document, "#global-default-agent-select [data-select-label]")
           ) =~ "Escalation"
  end

  test "timezone uses saved value before browser detection and retains its hook" do
    for {saved, detected, expected} <- [
          {"GMT+03:00", "GMT+01:00", "GMT+03:00"},
          {nil, "GMT+01:00", "GMT+01:00"},
          {nil, nil, ""}
        ] do
      html =
        render_component(&GlobalTab.panel/1,
          global_agent_options: [],
          global_default_agent_id: nil,
          global_base_url: "",
          global_language: "en",
          global_timezone: saved,
          detected_timezone: detected
        )

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(
               LazyHTML.query(document, "#global-timezone-select input[name='timezone']"),
               "value"
             ) == [expected]

      assert LazyHTML.attribute(LazyHTML.query(document, "#global-timezone-section"), "phx-hook") ==
               ["DetectTimezone"]

      assert LazyHTML.text(
               LazyHTML.query(document, "#global-timezone-select [data-select-label]")
             ) =~ if(expected == "", do: "—", else: expected)
    end
  end
end
