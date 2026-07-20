defmodule ZaqWeb.Components.MarkdownEditorTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.MarkdownEditor

  describe "markdown_view/1" do
    test "renders an empty preview message for blank content" do
      html =
        render_component(&MarkdownEditor.markdown_view/1,
          id: "approval-preview",
          content: "   "
        )

      assert html =~ ~s(id="approval-preview")
      assert html =~ ~s(phx-hook="MarkdownHighlight")
      assert html =~ "Nothing to preview."
    end

    test "renders sanitized markdown content" do
      html =
        render_component(&MarkdownEditor.markdown_view/1,
          id: "approval-preview",
          content: "## Review\n\n<script>alert('x')</script>\n\n**Ship it**"
        )

      assert html =~ "<h2>"
      assert html =~ "Review"
      assert html =~ "<strong>Ship it</strong>"
      refute html =~ "<script>"
    end
  end
end
