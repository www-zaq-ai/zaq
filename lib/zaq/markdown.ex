defmodule Zaq.Markdown do
  @moduledoc """
  Shared safe Markdown-to-HTML conversion for channel delivery and BO previews.

  Embedded HTML is preserved through rendering and then sanitized using MDEx's
  default policy, including its allowed styles. Explicit `_blank` links and
  validated image sources extend that policy without broadening hyperlink URL
  schemes. Code highlighting is left to the consumer. The `:smart` option
  controls typographic punctuation.
  """

  alias Zaq.Markdown.ImageSources

  @spec to_html(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def to_html(content, opts \\ []) do
    case MDEx.to_html(content,
           parse: [smart: Keyword.get(opts, :smart, true)],
           extension: [table: true, strikethrough: true, autolink: true, tasklist: true],
           render: [unsafe: true, escape: false, hardbreaks: true],
           sanitize: nil,
           syntax_highlight: false
         ) do
      {:ok, html} when is_binary(html) -> {:ok, sanitize(html)}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_mdex_output, other}}
    end
  rescue
    error -> {:error, error}
  end

  defp sanitize(html) do
    options =
      MDEx.Document.default_sanitize_options()
      |> Keyword.put(:add_tag_attribute_values, %{"a" => %{"target" => ["_blank"]}})
      |> Keyword.put(:add_tag_attributes, %{"img" => ["srcset"]})

    {protected, sources} = ImageSources.protect(html)

    protected
    |> MDEx.safe_html(
      sanitize: options,
      escape: [content: false, curly_braces_in_code: false]
    )
    |> ImageSources.restore(sources)
  end
end
