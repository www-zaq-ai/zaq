defmodule Zaq.MarkdownTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Markdown

  @data "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9ioAAAAASUVORK5CYII="
  @blob "blob:https://example.com/550e8400-e29b-41d4-a716-446655440000"

  test "only explicitly authored blank targets survive with rel protections" do
    {:ok, html} =
      Markdown.to_html(
        ~s|<a href="/one" target="_blank" rel="opener">one</a><a href="/two">two</a>|
      )

    assert attribute(html, "a", "target") == ["_blank"]
    assert attribute(html, "a", "rel") == ["noopener noreferrer", "noopener noreferrer"]
  end

  property "unsupported named targets are rejected" do
    check all(target <- string(:alphanumeric, min_length: 1)) do
      {:ok, html} = Markdown.to_html(~s|<a href="/" target="#{target}">link</a>|)
      assert attribute(html, "a", "target") == []
      assert attribute(html, "a", "rel") == ["noopener noreferrer"]
    end
  end

  test "self, parent and top targets are not allowed" do
    for target <- ["_self", "_parent", "_top"] do
      {:ok, html} = Markdown.to_html(~s|<a target="#{target}" href="/">link</a>|)
      assert attribute(html, "a", "target") == []
    end
  end

  test "data-image and blob sources are preserved only on images" do
    for url <- [@data, @blob, "blob:null/550e8400-e29b-41d4-a716-446655440000"] do
      {:ok, html} = Markdown.to_html(~s|<img src="#{url}"><a href="#{url}">link</a>|)
      assert attribute(html, "img", "src") == [url]
      assert attribute(html, "a", "href") == []
    end
  end

  test "Markdown images support data and blob sources too" do
    for url <- [@data, @blob] do
      {:ok, html} = Markdown.to_html("![image](#{url})")
      assert attribute(html, "img", "src") == [url]
    end
  end

  test "default sanitizer recognizes case-insensitive blank without accepting named targets" do
    {:ok, html} = Markdown.to_html(~s|<a target="_BLANK" href="/">link</a>|)
    assert attribute(html, "a", "target") == ["_BLANK"]
    assert attribute(html, "a", "rel") == ["noopener noreferrer"]
  end

  test "descriptor-free data images and comma-delimited URL candidates survive" do
    {:ok, html} = Markdown.to_html(~s|<img srcset="#{@data}, /normal.png">|)
    assert attribute(html, "img", "srcset") == ["#{@data}, /normal.png"]
  end

  test "empty or wholly invalid srcset is removed" do
    for srcset <- ["", "javascript:evil 1x", "data:text/html,evil 2x", "/invalid.png -1w"] do
      {:ok, html} = Markdown.to_html(~s|<img src="/fallback.png" srcset="#{srcset}">|)
      assert attribute(html, "img", "srcset") == []
      assert attribute(html, "img", "src") == ["/fallback.png"]
    end
  end

  test "srcset preserves normal URLs and width or density descriptors" do
    for srcset <- [
          "/small.png 320w, https://example.com/large.png 640w",
          "small.png 1x, //example.com/large.png 2x"
        ] do
      {:ok, html} = Markdown.to_html(~s|<img src="/fallback.png" srcset="#{srcset}">|)
      assert attribute(html, "img", "srcset") == [srcset]
      assert attribute(html, "img", "src") == ["/fallback.png"]
    end
  end

  test "srcset data URL commas and blob URLs are not split into extra candidates" do
    srcset = "#{@data} 1x, #{@blob} 2x"
    {:ok, html} = Markdown.to_html(~s|<img srcset="#{srcset}">|)
    assert attribute(html, "img", "srcset") == [srcset]

    data = "data:image/svg+xml,%3Csvg%20viewBox='0,0,1,1'%3E%3C/svg%3E"
    {:ok, html} = Markdown.to_html(~s|<img srcset="#{data} 1x, /large.svg 2x">|)
    assert attribute(html, "img", "srcset") == ["#{data} 1x, /large.svg 2x"]
  end

  test "unsafe schemes are rejected in links, src and each srcset candidate" do
    for url <- [
          "javascript:alert(1)",
          "vbscript:evil",
          "data:text/html;base64,PHNjcmlwdD4=",
          "blob:javascript:evil"
        ] do
      {:ok, html} =
        Markdown.to_html(
          ~s|<a href="#{url}">link</a><img src="#{url}" srcset="#{url} 1x, /safe.png 2x">|
        )

      assert attribute(html, "a", "href") == []
      assert attribute(html, "img", "src") == []
      assert attribute(html, "img", "srcset") == ["/safe.png 2x"]
    end
  end

  test "HTML entity encoded schemes and control bytes cannot bypass candidate validation" do
    for url <- [
          "java&#x73;cript:evil",
          "java&#9;script:evil",
          "java&#10;script:evil",
          "&#106;avascript:evil"
        ] do
      {:ok, html} =
        Markdown.to_html(~s|<img srcset="#{url} 1x, /safe.png 2x"><a href="#{url}">x</a>|)

      assert attribute(html, "img", "srcset") == ["/safe.png 2x"]
      assert attribute(html, "a", "href") == []
    end
  end

  test "invalid descriptor candidates are dropped without losing valid neighbors" do
    {:ok, html} =
      Markdown.to_html(
        ~s|<img srcset="/a.png 1x 2x, /b.png -1w, /c.png (bad, descriptor), /good.png 2x">|
      )

    assert attribute(html, "img", "srcset") == ["/good.png 2x"]
  end

  property "validated width candidates round-trip through sanitization" do
    check all(width <- integer(1..100_000), name <- string(:alphanumeric, min_length: 1)) do
      srcset = "/#{name}.png #{width}w"
      {:ok, html} = Markdown.to_html(~s|<img srcset="#{srcset}">|)
      assert attribute(html, "img", "srcset") == [srcset]
    end
  end

  test "image extensions do not preserve event handlers or change default style support" do
    {:ok, html} =
      Markdown.to_html(
        ~s|<div style="color: red"><img src="#{@data}" srcset="#{@blob} 2x" onerror="evil()"></div>|
      )

    assert attribute(html, "div", "style") == ["color: red"]
    assert attribute(html, "img", "onerror") == []
    assert attribute(html, "img", "src") == [@data]
  end

  test "image markup inside inline and fenced code remains escaped code" do
    markup = ~s|<img src="#{@data}" srcset="#{@blob} 2x">|
    {:ok, html} = Markdown.to_html("`#{markup}`\n\n```html\n#{markup}\n```")
    assert attribute(html, "img", "src") == []
    assert html =~ "&lt;img"
    assert html =~ ~s(class="language-html")
  end

  defp attribute(html, selector, name) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end
end
