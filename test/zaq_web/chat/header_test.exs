defmodule ZaqWeb.Chat.HeaderTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Chat.Header

  test "empty selection inherits routing without advertising a built-in pipeline" do
    html = render_component(&Header.chat_header/1, selected_agent_id: "", available_agents: [])

    assert html =~ "Default (routing)"
    refute html =~ "Default pipeline"
    assert html =~ ~s(name="agent_id")
    assert html =~ ~s(value="")
  end

  test "configured agents remain selectable without choosing the first automatically" do
    html =
      render_component(&Header.chat_header/1,
        selected_agent_id: 42,
        available_agents: [%{id: 42, name: "Knowledge Agent"}]
      )

    assert html =~ "Knowledge Agent"
    assert html =~ ~s(value="42")
    assert html =~ "Default (routing)"
  end
end
