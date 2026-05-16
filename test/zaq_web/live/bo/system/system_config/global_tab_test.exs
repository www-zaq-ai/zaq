defmodule ZaqWeb.Live.BO.System.SystemConfig.GlobalTabTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Live.BO.System.SystemConfig.GlobalTab

  test "panel renders default option selected when no global default agent is set" do
    html =
      render_component(&GlobalTab.panel/1,
        global_agent_options: [],
        global_default_agent_id: nil,
        global_base_url: ""
      )

    assert html =~ "Global"
    assert html =~ "Global Base URL"
    assert html =~ "Global Default Agent"
    assert html =~ "Default Zaq Agent"
    assert html =~ ~s(id="global-base-url-input")
    assert html =~ ~s(phx-submit="save_global_base_url")
    assert html =~ ~s(id="global-default-agent-select")
    assert html =~ ~s(phx-submit="save_global_default_agent")
    assert html =~ ~s(<option value="" selected>)
  end

  test "panel selects configured global default agent" do
    html =
      render_component(&GlobalTab.panel/1,
        global_agent_options: [{"Answering", 1}, {"Escalation", 2}],
        global_default_agent_id: 2,
        global_base_url: "https://zaq.example"
      )

    assert html =~ "Answering"
    assert html =~ "Escalation"
    assert html =~ ~s(value="https://zaq.example")
    assert html =~ ~s(<option value="2" selected>)
    refute html =~ ~s(<option value="" selected>)
  end
end
