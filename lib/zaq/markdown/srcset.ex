defmodule Zaq.Markdown.Srcset do
  @moduledoc """
  Tokenizes image srcset candidates without splitting commas inside URLs.

  Follows the HTML srcset URL/descriptor tokenization states, including
  parenthesized descriptors. Only the supported single width or density
  descriptor forms are retained; invalid candidates are discarded.
  See https://html.spec.whatwg.org/multipage/images.html#parse-a-srcset-attribute.
  """

  @space [9, 10, 12, 13, 32]

  @spec parse(String.t()) :: [{String.t(), String.t()}]
  def parse(value), do: candidates(value, [])

  defp candidates(<<c, rest::binary>>, acc) when c in @space or c == ?,,
    do: candidates(rest, acc)

  defp candidates("", acc), do: Enum.reverse(acc)

  defp candidates(input, acc) do
    {url, rest} = url(input, "")

    if String.ends_with?(url, ",") do
      candidates(rest, [{String.trim_trailing(url, ","), ""} | acc])
    else
      {descriptor, rest} = descriptors(rest, "", 0)

      case normalize_descriptor(descriptor) do
        {:ok, descriptor} -> candidates(rest, [{url, descriptor} | acc])
        :error -> candidates(rest, acc)
      end
    end
  end

  defp url(<<c, _::binary>> = rest, acc) when c in @space, do: {acc, rest}
  defp url(<<c, rest::binary>>, acc), do: url(rest, <<acc::binary, c>>)
  defp url("", acc), do: {acc, ""}

  defp descriptors("", acc, _depth), do: {acc, ""}
  defp descriptors(<<?,, rest::binary>>, acc, 0), do: {acc, rest}

  defp descriptors(<<?(, rest::binary>>, acc, depth),
    do: descriptors(rest, acc <> "(", depth + 1)

  defp descriptors(<<?), rest::binary>>, acc, depth),
    do: descriptors(rest, acc <> ")", max(depth - 1, 0))

  defp descriptors(<<c, rest::binary>>, acc, depth),
    do: descriptors(rest, <<acc::binary, c>>, depth)

  defp normalize_descriptor(value) do
    case String.split(value, [" ", "\t", "\n", "\r", "\f"], trim: true) do
      [] -> {:ok, ""}
      [descriptor] -> validate_descriptor(descriptor)
      _ -> :error
    end
  end

  defp validate_descriptor(value) do
    {number, suffix} = String.split_at(value, -1)

    case {suffix, Integer.parse(number), Float.parse(number)} do
      {"w", {width, ""}, _} when width > 0 -> positive_descriptor(value, number)
      {"x", _, {density, ""}} when density >= 0 -> positive_descriptor(value, number)
      _ -> :error
    end
  end

  defp positive_descriptor(value, number) do
    if String.starts_with?(number, ["+", "-"]), do: :error, else: {:ok, value}
  end
end
