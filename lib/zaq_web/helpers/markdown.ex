defmodule ZaqWeb.Helpers.Markdown do
  @moduledoc """
  Markdown rendering helper for chat and preview surfaces.

  Strategy:
  - Convert markdown and embedded HTML with the shared `Zaq.Markdown` renderer.
  - Apply MDEx's default sanitizer and return escaped text on conversion errors.
  """

  @spec render(String.t(), keyword()) :: String.t()
  def render(content, opts \\ [])

  def render(content, opts) when is_binary(content) do
    case Zaq.Markdown.to_html(content, opts) do
      {:ok, html} -> html
      {:error, _} -> fallback(content)
    end
  end

  def render(_, _), do: ""

  defp fallback(content) do
    escaped = content |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    "<pre>#{escaped}</pre>"
  end
end
