defmodule Zaq.Utils.HtmlUtils do
  @moduledoc """
  Helpers for converting HTML fragments to readable plain text.
  """

  @spec html_to_text(String.t()) :: String.t()
  def html_to_text(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/iu, "\n")
    |> String.replace(~r/<\/h[1-6]>/iu, "\n")
    |> String.replace(~r/<\/p>/iu, "\n")
    |> String.replace(~r/<\/div>/iu, "\n")
    |> String.replace(~r/<\/blockquote>/iu, "\n")
    |> String.replace(~r/<\/li>/iu, "\n")
    |> String.replace(~r/<[^>]*>/u, "")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/[ \t]+\n/u, "\n")
    |> String.replace(~r/\n[ \t]+/u, "\n")
    |> String.replace(~r/\n[ \t]*\n[ \t]*\n+/u, "\n\n")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end
end
