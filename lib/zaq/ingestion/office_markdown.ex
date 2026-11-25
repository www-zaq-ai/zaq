defmodule Zaq.Ingestion.OfficeMarkdown do
  @moduledoc """
  Removes embedded-image references from Office Markdown when assets aren't exported.

  Use the parser's image spans to preserve surrounding converter output, including
  table delimiters, captions, links, and literal Markdown examples.
  """

  @doc "Drops Markdown images without reformatting the rest of the document."
  @spec ignore_images(String.t()) :: String.t()
  def ignore_images(markdown) when is_binary(markdown) do
    with true <- String.contains?(markdown, "!["),
         {:ok, document} <- MDEx.parse_document(markdown, extension: [table: true]) do
      line_offsets = line_offsets(markdown)

      document
      |> Enum.flat_map(&image_range(&1, line_offsets, markdown))
      |> Enum.sort()
      |> remove_ranges(markdown)
    else
      _ -> markdown
    end
  end

  defp line_offsets(markdown) do
    markdown
    |> :binary.matches("\n")
    |> Enum.map(fn {offset, _length} -> offset + 1 end)
    |> then(&List.to_tuple([0 | &1]))
  end

  defp image_range(%MDEx.Image{sourcepos: sourcepos}, line_offsets, markdown) do
    %MDEx.Sourcepos{start: {first_line, first_column}, end: {last_line, last_column}} =
      sourcepos

    with {:ok, first} <- byte_offset(line_offsets, first_line, first_column),
         {:ok, last} <- byte_offset(line_offsets, last_line, last_column),
         true <- last > first and last < byte_size(markdown),
         "![" <- binary_part(markdown, first, 2) do
      [{first, last + 1}]
    else
      _ -> []
    end
  end

  defp image_range(_node, _line_offsets, _markdown), do: []

  defp byte_offset(line_offsets, line, column)
       when line > 0 and line <= tuple_size(line_offsets) and column > 0,
       do: {:ok, elem(line_offsets, line - 1) + column - 1}

  defp byte_offset(_line_offsets, _line, _column), do: :error

  defp remove_ranges([], markdown), do: markdown

  defp remove_ranges(ranges, markdown) do
    {prefixes, offset} =
      Enum.reduce(ranges, {[], 0}, fn
        {first, last}, {prefixes, offset} when first >= offset ->
          {[binary_part(markdown, offset, first - offset) | prefixes], last}

        {_first, last}, {prefixes, offset} ->
          {prefixes, max(last, offset)}
      end)

    tail = binary_part(markdown, offset, byte_size(markdown) - offset)
    IO.iodata_to_binary(Enum.reverse(prefixes, [tail]))
  end
end
