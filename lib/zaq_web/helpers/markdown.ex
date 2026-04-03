defmodule ZaqWeb.Helpers.Markdown do
  @moduledoc """
  Markdown rendering helper for chat and preview surfaces.

  Strategy:
  - Convert markdown to HTML with `Earmark`.
  - Apply a lightweight regex-based sanitization pass to remove common XSS vectors
    (`<script>` blocks, `on*` attributes, `javascript:` URLs).

  Security note:
  This is a pragmatic hardening layer, not a full HTML parser/sanitizer. If the
  threat model expands, migrate this to a dedicated HTML sanitization library.
  """

  @spec render(String.t()) :: String.t()
  def render(content) when is_binary(content) do
    case Earmark.as_html(content, escape: true, breaks: true) do
      {:ok, html, _} -> sanitize_html(html)
      {:error, _, _} -> fallback(content)
    end
  end

  def render(_), do: ""

  defp fallback(content) do
    escaped = content |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    "<pre>#{escaped}</pre>"
  end

  defp sanitize_html(html) do
    html
    |> then(&Regex.replace(~r/<script\b[^>]*>[\s\S]*?<\/script>/iu, &1, ""))
    |> then(&Regex.replace(~r/\s+on\w+=("[^"]*"|'[^']*'|[^\s>]+)/iu, &1, ""))
    |> then(&Regex.replace(~r/\s+href=("|')\s*javascript:[^"']*("|')/iu, &1, ~s( href="#")))
    |> then(&Regex.replace(~r/\s+src=("|')\s*javascript:[^"']*("|')/iu, &1, ""))
  end
end
