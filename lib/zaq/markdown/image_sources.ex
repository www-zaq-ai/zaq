defmodule Zaq.Markdown.ImageSources do
  @moduledoc """
  Image-scoped URL handling around MDEx's default HTML sanitizer.

  Ammonia does not parse srcset and its URL scheme policy is global. Validated
  image values therefore travel through sanitization as unique HTTPS tokens.
  Only matching img src/srcset attributes are restored, using an HTML serializer.
  Hyperlinks never receive additional URL schemes. No HTML is parsed by regex.

  Blob URLs remain dependent on the viewing browser's origin and object lifetime;
  allowing a URL cannot make a revoked or foreign-browser resource available.
  """

  alias Zaq.Markdown.Srcset

  @spec protect(String.t()) :: {String.t(), map()}
  def protect(html) do
    prefix = "https://zaq-image.invalid/" <> Base.url_encode64(:crypto.strong_rand_bytes(24))

    {tree, sources} =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.to_tree()
      |> LazyHTML.Tree.postwalk(%{}, fn
        {"img", attrs, children}, sources ->
          {attrs, sources} = protect_attributes(attrs, sources, prefix)
          {{"img", attrs, children}, sources}

        node, sources ->
          {node, sources}
      end)

    {LazyHTML.Tree.to_html(tree), sources}
  end

  @spec restore(String.t(), map()) :: String.t()
  def restore(html, sources) when map_size(sources) == 0, do: html

  def restore(html, sources) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.to_tree()
    |> LazyHTML.Tree.postwalk(fn
      {"img", attrs, children} ->
        attrs =
          Enum.map(attrs, fn {key, value} ->
            {key, Map.get(sources, {key, value}, value)}
          end)

        {"img", attrs, children}

      node ->
        node
    end)
    |> LazyHTML.Tree.to_html()
  end

  defp protect_attributes(attrs, sources, prefix) do
    Enum.flat_map_reduce(attrs, sources, fn
      {"srcset", value}, sources ->
        value =
          value
          |> Srcset.parse()
          |> Enum.filter(fn {url, _} -> safe_image_url?(url) end)
          |> Enum.map_join(", ", fn {url, descriptor} -> String.trim(url <> " " <> descriptor) end)

        protect_value("srcset", value, sources, prefix)

      {"src", value} = attr, sources ->
        protect_src(attr, value, sources, prefix)

      attr, sources ->
        {[attr], sources}
    end)
  end

  defp protect_src(attr, value, sources, prefix) do
    cond do
      not String.starts_with?(String.downcase(String.trim(value)), ["data:", "blob:"]) ->
        {[attr], sources}

      safe_image_url?(value) ->
        protect_value("src", String.trim(value), sources, prefix)

      true ->
        {[], sources}
    end
  end

  defp protect_value(_key, "", sources, _prefix), do: {[], sources}

  defp protect_value(key, value, sources, prefix) do
    token = prefix <> "/" <> Integer.to_string(map_size(sources))
    {[{key, token}], Map.put(sources, {key, token}, value)}
  end

  defp safe_image_url?(value) do
    # Reject browser-stripped control bytes rather than interpreting a different
    # scheme from the browser. HTML entities have already been decoded by Lexbor.
    value != "" and
      not Enum.any?(:binary.bin_to_list(value), &(&1 < 32 or &1 == 127)) and
      allowed_image_uri?(URI.parse(String.trim(value)))
  end

  defp allowed_image_uri?(%URI{scheme: nil}), do: true

  defp allowed_image_uri?(%URI{scheme: scheme} = uri) do
    case String.downcase(scheme) do
      "data" -> image_data?(uri.path)
      "blob" -> blob_origin?(uri.path)
      scheme -> scheme in MDEx.Document.default_sanitize_options()[:url_schemes]
    end
  end

  defp image_data?(path) when is_binary(path) do
    case String.split(path, ",", parts: 2) do
      [header, data] when data != "" ->
        media_type = header |> String.split(";", parts: 2) |> hd() |> String.downcase()
        String.starts_with?(media_type, "image/") and byte_size(media_type) > 6

      _ ->
        false
    end
  end

  defp image_data?(_), do: false

  defp blob_origin?("null/" <> id), do: id != ""

  defp blob_origin?(path) when is_binary(path) do
    case URI.parse(path) do
      %URI{scheme: scheme, host: host, path: "/" <> id}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and id != "" ->
        true

      _ ->
        false
    end
  end

  defp blob_origin?(_), do: false
end
