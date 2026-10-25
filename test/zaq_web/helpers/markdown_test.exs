defmodule ZaqWeb.Helpers.MarkdownTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Helpers.Markdown

  describe "render/1" do
    test "returns empty string for non-binary input" do
      assert Markdown.render(nil) == ""
      assert Markdown.render(%{}) == ""
    end

    test "renders markdown and strips unsafe tags" do
      html = Markdown.render("**Bold**\n\n<script>alert('x')</script>")

      assert html =~ "<strong>Bold</strong>"
      refute html =~ "<script"
    end

    test "strips script tags case-insensitively" do
      html = Markdown.render("ok<SCRIPT>alert('x')</SCRIPT>")

      assert html =~ "ok"
      refute html =~ ~r/<script/i
    end

    test "preserves embedded links while removing unsafe attributes" do
      html = Markdown.render(~s|<a href="javascript:alert('x')" onclick="evil()">click</a>|)

      assert html =~ "click"
      assert html =~ "<a "
      assert html =~ ">click</a>"
      refute html =~ "javascript:"
      refute html =~ "onclick="
    end

    test "preserves embedded images while removing single and unquoted event handlers" do
      html = Markdown.render(~s|<img src="x" onload='evil()' onerror=evil()>|)

      assert html =~ ~s(<img src="x")
      refute html =~ "onload="
      refute html =~ "onerror="
    end

    test "removes javascript href from embedded HTML" do
      html = Markdown.render(~s|<a href='javascript:alert(1)'>x</a>|)

      assert html =~ ">x</a>"
      refute html =~ "href="
      refute html =~ "javascript:"
    end

    test "removes javascript src from embedded HTML" do
      html = Markdown.render(~s|<img src="javascript:alert(1)">|)

      assert html =~ "<img>"
      refute html =~ "src="
      refute html =~ "javascript:"
    end

    test "preserves supported HTML and default allowed styles" do
      html =
        Markdown.render(
          ~s|<details><summary>More</summary><div style="color: red; text-align: center" onclick="evil()"><strong>Bold</strong> <em>italic</em></div><a href="https://example.com">link</a><img src="https://example.com/image.png" alt="image"></details>|
        )

      assert html =~ "<details>"
      assert html =~ "<summary>More</summary>"
      assert html =~ ~s(style="color: red; text-align: center")
      assert html =~ "<strong>Bold</strong>"
      assert html =~ "<em>italic</em>"
      assert html =~ ~s(href="https://example.com")
      assert html =~ ~s(rel="noopener noreferrer")
      assert html =~ ~s(src="https://example.com/image.png")
      refute html =~ "onclick="
    end

    test "retains default style attributes on div, span and pre" do
      for tag <- ["div", "span", "pre"] do
        html = Markdown.render(~s|<#{tag} style="color: blue">styled</#{tag}>|)

        assert html =~ ~s|<#{tag} style="color: blue">styled</#{tag}>|
      end
    end

    test "HTML examples inside inline and fenced code stay escaped" do
      html = Markdown.render("`<b>example</b>`\n\n```html\n<script>evil()</script>\n```")

      assert html =~ "<code>&lt;b&gt;example&lt;/b&gt;</code>"
      assert html =~ "&lt;script&gt;evil()&lt;/script&gt;"
      assert html =~ ~s(<code class="language-html">)
      refute html =~ "<script"
    end

    test "rejects dangerous URLs in Markdown links and images" do
      html = Markdown.render("[click](javascript:alert%281%29) ![image](javascript:alert%281%29)")

      refute html =~ "javascript:"
      assert html =~ "click"
    end

    test "quotes in Markdown link titles cannot introduce attributes" do
      html = Markdown.render(~s|[click](https://example.com 'title" onclick="evil()')|)

      assert html =~ "&quot;"
      refute html =~ ~s| onclick="evil()|
    end

    test "preserves hard breaks, tables, strikethrough and fenced code" do
      html =
        Markdown.render(
          "one\ntwo\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n~~gone~~\n\n```elixir\n:ok\n```"
        )

      assert html =~ "one<br"
      assert html =~ "<table>"
      assert html =~ "<del>gone</del>"
      assert html =~ ~s(<code class="language-elixir">)
    end

    test "renders list markdown" do
      html = Markdown.render("- one\n- two")

      assert html =~ "<ul>"
      assert html =~ "<li>"
      assert html =~ "one"
      assert html =~ "two"
    end
  end
end
