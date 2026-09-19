defmodule ZaqWeb.Components.DesignSystem.FeedbackBannerTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.FeedbackBanner

  test "renders accessible success feedback with LiveView dismissal" do
    html =
      render_component(&FeedbackBanner.feedback_banner/1,
        kind: :info,
        message: "Credential saved."
      )

    assert html =~ ~s(id="flash-info")
    assert html =~ ~s(role="status")
    assert html =~ "zaq-success"
    assert html =~ "Credential saved."
    assert html =~ ~s(phx-click="lv:clear-flash")
    assert html =~ ~s(phx-value-key="info")
  end

  test "renders accessible error feedback and escapes message content" do
    html =
      render_component(&FeedbackBanner.feedback_banner/1,
        kind: :error,
        message: "Unable to save <credential>."
      )

    assert html =~ ~s(id="flash-error")
    assert html =~ ~s(role="alert")
    assert html =~ "zaq-danger"
    assert html =~ "Unable to save &lt;credential&gt;."
    refute html =~ "Unable to save <credential>."
  end

  test "adds the trusted user portal link after escaping the message" do
    html =
      render_component(&FeedbackBanner.feedback_banner/1,
        kind: :error,
        message: "Open the user portal for <Alice>."
      )

    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
    assert html =~ ">user portal</a>"
    assert html =~ "&lt;Alice&gt;"
  end
end
