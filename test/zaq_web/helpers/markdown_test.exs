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

    test "strips unsafe attributes" do
      html = Markdown.render(~s|<a href="javascript:alert('x')" onclick="evil()">click</a>|)

      assert html =~ "click"
      refute html =~ "javascript:"
      refute html =~ "onclick="
    end

    test "strips on* attributes with single and unquoted values" do
      html = Markdown.render(~s|<img src="x" onload='evil()' onerror=evil()>|)

      refute html =~ "onload="
      refute html =~ "onerror="
    end

    test "replaces javascript href with safe placeholder" do
      html = Markdown.render(~s|<a href='javascript:alert(1)'>x</a>|)

      assert html =~ ~s(href="#")
      refute html =~ "javascript:"
    end

    test "removes javascript src from raw html input" do
      html = Markdown.render(~s|<img src="javascript:alert(1)">|)

      refute html =~ ~s(src="javascript:)
      assert html =~ "<img>"
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
