defmodule ZaqWeb.Helpers.Markdown do
  @moduledoc false

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
