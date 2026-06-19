defmodule ZaqWeb.Components.DesignSystem.DiagnosticCardTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.DiagnosticCard

  test "diagnostic_card/1 renders label, status, and test button" do
    html =
      render_component(&DiagnosticCard.diagnostic_card/1,
        label: "LLM",
        status: :idle,
        event: "test_llm",
        inner_block: [%{inner_block: fn _, _ -> "body" end}]
      )

    assert html =~ "LLM"
    assert html =~ "idle"
    assert html =~ "test_llm"
    assert html =~ "body"
  end
end
