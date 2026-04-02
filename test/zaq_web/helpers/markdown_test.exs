defmodule ZaqWeb.Helpers.MarkdownTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Helpers.Markdown

  describe "render/1" do
    test "renders markdown and strips unsafe tags" do
      html = Markdown.render("**Bold**\n\n<script>alert('x')</script>")

      assert html =~ "<strong>Bold</strong>"
      refute html =~ "<script"
    end

    test "strips unsafe attributes" do
      html = Markdown.render(~s|<a href="javascript:alert('x')" onclick="evil()">click</a>|)

      assert html =~ "click"
      refute html =~ "javascript:"
      refute html =~ "onclick="
    end
  end
end
