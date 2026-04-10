defmodule Zaq.Ingestion.DocumentChunker do
  @moduledoc """
  Layout-aware, hierarchical section-level chunking for RAG systems.

  This module handles:
  - Detecting natural sections (headings, tables, captions, figures)
  - Chunking sections into configurable token pieces (default 400-900)

  Token limits are read from application config:

      config :zaq, Zaq.Ingestion,
        chunk_min_tokens: 400,
        chunk_max_tokens: 900
  """

  require Logger

  alias Zaq.Agent.TokenEstimator

  defmodule Section do
    @moduledoc "Represents a document section with metadata."
    defstruct [
      :id,
      # :heading, :paragraph, :table, :figure, :caption
      :type,
      # heading level (1-6) or nil
      :level,
      :title,
      :content,
      # ["Chapter 1", "Section 1.1"]
      :parent_path,
      # original position in document
      :position,
      :tokens
    ]
  end

  defmodule Chunk do
    @moduledoc "Represents a chunk with metadata."
    defstruct [
      :id,
      :section_id,
      :content,
      # ["Chapter 1", "Section 1.1", "Subsection 1.1.1"]
      :section_path,
      :tokens,
      :metadata
    ]
  end

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  defp chunk_min_tokens do
    Zaq.System.get_embedding_config().chunk_min_tokens
  end

  defp chunk_max_tokens do
    Zaq.System.get_embedding_config().chunk_max_tokens
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Parse a document and extract sections based on layout.

  ## Options

    * `:format` - `:markdown` (default), `:html`, or `:text`

  ## Examples

      iex> markdown = "# Introduction\\n\\nSome content."
      iex> sections = Zaq.Ingestion.DocumentChunker.parse_layout(markdown)
      iex> length(sections) > 0
      true
      iex> hd(sections).type
      :heading
  """
  def parse_layout(text, opts \\ []) when is_binary(text) do
    if String.trim(text) == "" do
      []
    else
      format = Keyword.get(opts, :format, :markdown)

      case format do
        :markdown -> parse_markdown(text)
        :html -> parse_html(text)
        :text -> parse_plain_text(text)
        _ -> {:error, {:invalid_format, format}}
      end
    end
  end

  @doc """
  Chunk sections into token-bounded pieces.

  Min/max token sizes are read from `config :zaq, Zaq.Ingestion`.
  """
  def chunk_sections(sections, _opts \\ []) when is_list(sections) do
    sections
    |> Enum.filter(fn section ->
      String.trim(section.content || "") != ""
    end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {section, idx} ->
      chunk_section(section, idx)
    end)
  end

  # ---------------------------------------------------------------------------
  # Markdown parsing
  # ---------------------------------------------------------------------------

  defp parse_markdown(text) do
    lines = String.split(text, "\n")
    parse_markdown_lines(lines, [], [], nil, [], 0)
  end

  defp parse_markdown_lines(
         [],
         sections,
         current_content,
         current_section,
         _heading_stack,
         _position
       ) do
    sections = maybe_add_section(sections, current_content, current_section)
    Enum.reverse(sections)
  end

  defp parse_markdown_lines(
         [line | rest],
         sections,
         current_content,
         current_section,
         heading_stack,
         position
       ) do
    cond do
      heading = parse_any_heading(line) ->
        handle_heading(
          line,
          heading,
          rest,
          sections,
          current_content,
          current_section,
          heading_stack,
          position
        )

      table_line?(line) ->
        handle_table(
          line,
          rest,
          sections,
          current_content,
          current_section,
          heading_stack,
          position
        )

      vision_image_block?(line) ->
        handle_vision_image(
          line,
          rest,
          sections,
          current_content,
          current_section,
          heading_stack,
          position
        )

      String.match?(line, ~r/^!\[.*\]\(.*\)/) ->
        handle_figure(
          line,
          rest,
          sections,
          current_content,
          current_section,
          heading_stack,
          position
        )

      html_comment?(line) ->
        parse_markdown_lines(
          rest,
          sections,
          current_content,
          current_section,
          heading_stack,
          position + 1
        )

      true ->
        new_content = [line | current_content]

        parse_markdown_lines(
          rest,
          sections,
          new_content,
          current_section,
          heading_stack,
          position + 1
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Heading detection
  # ---------------------------------------------------------------------------

  defp parse_any_heading(line) do
    parse_heading(line) || parse_bold_heading(line) || parse_italic_heading(line)
  end

  defp handle_heading(
         _line,
         {level, title},
         rest,
         sections,
         current_content,
         current_section,
         heading_stack,
         position
       ) do
    sections = maybe_add_section(sections, current_content, current_section)
    parent_path = build_parent_path_from_stack(heading_stack, level)

    new_section = %Section{
      id: generate_id(),
      type: :heading,
      level: level,
      title: title,
      parent_path: parent_path,
      position: position,
      content: "",
      tokens: 0
    }

    new_stack = update_heading_stack(heading_stack, new_section)
    parse_markdown_lines(rest, sections, [], new_section, new_stack, position + 1)
  end

  # ---------------------------------------------------------------------------
  # Table handling
  # ---------------------------------------------------------------------------

  defp handle_table(
         line,
         rest,
         sections,
         current_content,
         current_section,
         heading_stack,
         position
       ) do
    {table_lines, remaining} = extract_table([line | rest])

    if length(table_lines) >= 2 do
      table_content = Enum.join(table_lines, "\n")
      parent_path = get_parent_path_for_non_heading_from_stack(heading_stack, current_section)

      table_section = %Section{
        id: generate_id(),
        type: :table,
        content: table_content,
        parent_path: parent_path,
        position: position,
        tokens: TokenEstimator.estimate(table_content)
      }

      sections = maybe_add_section(sections, current_content, current_section)
      sections = [table_section | sections]

      parse_markdown_lines(
        remaining,
        sections,
        [],
        current_section,
        heading_stack,
        position + length(table_lines)
      )
    else
      new_content = [line | current_content]

      parse_markdown_lines(
        rest,
        sections,
        new_content,
        current_section,
        heading_stack,
        position + 1
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Vision image block handling
  # ---------------------------------------------------------------------------

  defp handle_vision_image(
         line,
         rest,
         sections,
         current_content,
         current_section,
         heading_stack,
         position
       ) do
    {image_lines, remaining} = extract_vision_image_block([line | rest])
    image_content = Enum.join(image_lines, "\n")

    filename = extract_vision_image_filename(line)
    parent_path = get_parent_path_for_non_heading_from_stack(heading_stack, current_section)

    figure_section = %Section{
      id: generate_id(),
      type: :figure,
      content: image_content,
      title: filename,
      parent_path: parent_path,
      position: position,
      tokens: TokenEstimator.estimate(image_content)
    }

    sections = maybe_add_section(sections, current_content, current_section)
    sections = [figure_section | sections]

    parse_markdown_lines(
      remaining,
      sections,
      [],
      current_section,
      heading_stack,
      position + length(image_lines)
    )
  end

  # ---------------------------------------------------------------------------
  # Figure / image handling
  # ---------------------------------------------------------------------------

  defp handle_figure(
         line,
         rest,
         sections,
         current_content,
         current_section,
         heading_stack,
         position
       ) do
    caption = extract_image_caption(line)

    if should_skip_image?(line, caption) do
      parse_markdown_lines(
        rest,
        sections,
        current_content,
        current_section,
        heading_stack,
        position + 1
      )
    else
      parent_path = get_parent_path_for_non_heading_from_stack(heading_stack, current_section)

      figure_section = %Section{
        id: generate_id(),
        type: :figure,
        content: line,
        title: caption,
        parent_path: parent_path,
        position: position,
        tokens: TokenEstimator.estimate(line)
      }

      sections = maybe_add_section(sections, current_content, current_section)
      sections = [figure_section | sections]

      parse_markdown_lines(rest, sections, [], current_section, heading_stack, position + 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Vision image extraction
  # ---------------------------------------------------------------------------

  defp extract_vision_image_block(lines) do
    extract_vision_image_lines(lines, [])
  end

  defp extract_vision_image_lines([], acc), do: {Enum.reverse(acc), []}

  defp extract_vision_image_lines([line | rest], acc) do
    cond do
      acc == [] and vision_image_block?(line) ->
        extract_vision_image_lines(rest, [line | acc])

      acc != [] and String.trim(line) != "" and
        not String.starts_with?(line, "#") and
        not vision_image_block?(line) and
          not table_line?(line) ->
        extract_vision_image_lines(rest, [line | acc])

      true ->
        {Enum.reverse(acc), [line | rest]}
    end
  end

  defp extract_vision_image_filename(line) do
    case Regex.run(~r/\[Image:\s*([^\]]+)\]/, line) do
      [_, filename] -> String.trim(filename)
      nil -> "unknown"
    end
  end

  # ---------------------------------------------------------------------------
  # Line-type detection helpers
  # ---------------------------------------------------------------------------

  defp table_line?(line) do
    String.starts_with?(line, "|") && String.contains?(line, "|")
  end

  defp vision_image_block?(line) do
    String.match?(line, ~r/^>\s*\*\*\[Image:\s*[^\]]+\]\*\*/)
  end

  defp html_comment?(line) do
    String.match?(String.trim(line), ~r/^<!--.*-->$/)
  end

  defp bold_heading_candidate?(text) do
    word_count = text |> String.split(~r/\s+/, trim: true) |> length()

    cond do
      # Sentence-like: ends with terminating punctuation
      String.match?(text, ~r/[.!?»"]\s*$/) -> false
      # Too many words to be a title
      word_count > 8 -> false
      # Measurement: a bare number followed by a single unit word (e.g. "2.5 m", "20 cm")
      Regex.match?(~r/^\d+[\.,]?\d*\s+[a-zA-Z]+$/, text) -> false
      true -> true
    end
  end

  # ---------------------------------------------------------------------------
  # Heading parsers
  # ---------------------------------------------------------------------------

  defp parse_heading(line) do
    case Regex.run(~r/^(#+)\s+(.+)$/, line) do
      [_, hashes, title] -> {String.length(hashes), String.trim(title)}
      nil -> nil
    end
  end

  defp parse_bold_heading(line) do
    case Regex.run(~r/^\*\*(\d+(?:\.\d+)*\.?)\*\*\s+\*\*(.+?)\*\*\s*$/, line) do
      [_, number, title] -> handle_bold_numbered_heading(line, number, title)
      nil -> handle_bold_simple_heading(line)
    end
  end

  defp handle_bold_numbered_heading(line, number, title) do
    if Regex.match?(~r/\*\*\s*\d+\s*\*\*\s*$/, line) do
      nil
    else
      level = determine_heading_level(number)
      clean_title = String.trim(title)
      {level, "#{number} #{clean_title}"}
    end
  end

  defp handle_bold_simple_heading(line) do
    case Regex.run(~r/^\*\*([^*]+)\*\*\s*$/, line) do
      [_, title] ->
        if bold_heading_candidate?(String.trim(title)), do: process_bold_title(title), else: nil

      nil ->
        nil
    end
  end

  defp process_bold_title(title) do
    clean_title = String.trim(title)

    if Regex.match?(~r/^\d+(?:\.\d+)*\.?\s+/, clean_title) do
      extract_level_from_bold_title(clean_title)
    else
      handle_non_numbered_bold_title(title, clean_title)
    end
  end

  defp extract_level_from_bold_title(clean_title) do
    case Regex.run(~r/^(\d+(?:\.\d+)*\.?)\s+(.+)$/, clean_title) do
      [_, number, _text] ->
        level = determine_heading_level(number)
        {level, String.trim(clean_title)}

      nil ->
        {2, clean_title}
    end
  end

  defp handle_non_numbered_bold_title(title, clean_title) do
    if String.match?(title, ~r/\*\*\s*\d+\s*\*\*\s*$/) do
      nil
    else
      {2, clean_title}
    end
  end

  defp parse_italic_heading(line) do
    case Regex.run(~r/^_(\d+(?:\.\d+)*)_\s+_(.+?)_\s*$/, line) do
      [_, number, title] -> handle_numbered_heading(line, number, title)
      nil -> handle_simple_heading(line)
    end
  end

  defp handle_numbered_heading(line, number, title) do
    if Regex.match?(~r/_\s*\d+\s*_\s*$/, line) do
      nil
    else
      level = determine_heading_level(number)
      clean_title = String.trim(title)
      {level, "#{number} #{clean_title}"}
    end
  end

  defp handle_simple_heading(line) do
    case Regex.run(~r/^_([^_]+)_\s*$/, line) do
      [_, title] -> process_simple_title(title)
      nil -> nil
    end
  end

  defp process_simple_title(title) do
    clean_title = String.trim(title)

    if String.match?(title, ~r/_\s*\d+\s*_\s*$/) do
      nil
    else
      extract_heading_level(clean_title)
    end
  end

  defp extract_heading_level(clean_title) do
    if Regex.match?(~r/^\d+(?:\.\d+)*\s+/, clean_title) do
      case Regex.run(~r/^(\d+(?:\.\d+)*)\s+(.+)$/, clean_title) do
        [_, number, _text] ->
          level = determine_heading_level(number)
          {level, String.trim(clean_title)}

        nil ->
          {3, clean_title}
      end
    else
      {3, clean_title}
    end
  end

  defp determine_heading_level(number_str) do
    cleaned = String.trim_trailing(number_str, ".")
    dots = String.graphemes(cleaned) |> Enum.count(&(&1 == "."))
    min(dots + 1, 6)
  end

  # ---------------------------------------------------------------------------
  # Image helpers
  # ---------------------------------------------------------------------------

  defp should_skip_image?(line, caption) do
    caption == "" && String.match?(line, ~r/!\[\]\([^)]*\.pdf-[^)]+\)/)
  end

  defp extract_image_caption(line) do
    case Regex.run(~r/!\[(.*?)\]/, line) do
      [_, caption] -> caption
      nil -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # Table extraction
  # ---------------------------------------------------------------------------

  defp extract_table(lines) do
    extract_table_lines(lines, [], false)
  end

  defp extract_table_lines([], acc, _in_table), do: {Enum.reverse(acc), []}

  defp extract_table_lines([line | rest] = lines, acc, in_table) do
    cond do
      table_line?(line) ->
        extract_table_lines(rest, [line | acc], true)

      in_table && String.trim(line) == "" ->
        handle_empty_line_in_table(line, rest, acc, lines)

      in_table ->
        {Enum.reverse(acc), lines}

      true ->
        {Enum.reverse(acc), lines}
    end
  end

  defp handle_empty_line_in_table(line, rest, acc, lines) do
    case rest do
      [next_line | _] ->
        if table_line?(next_line) do
          extract_table_lines(rest, [line | acc], true)
        else
          {Enum.reverse(acc), lines}
        end

      _ ->
        {Enum.reverse(acc), lines}
    end
  end

  # ---------------------------------------------------------------------------
  # Path / stack helpers
  # ---------------------------------------------------------------------------

  defp build_parent_path_from_stack(heading_stack, level) do
    heading_stack
    |> Enum.filter(&(&1.level < level))
    |> Enum.map(& &1.title)
  end

  defp update_heading_stack(heading_stack, new_heading) do
    heading_stack
    |> Enum.filter(&(&1.level < new_heading.level))
    |> Kernel.++([new_heading])
  end

  defp get_current_path(nil), do: []

  defp get_current_path(%Section{parent_path: path, title: title}) when is_binary(title) do
    path ++ [title]
  end

  defp get_current_path(%Section{parent_path: path}), do: path

  defp get_parent_path_for_non_heading_from_stack(heading_stack, current_section) do
    case current_section do
      %Section{type: :heading} = sec ->
        get_current_path(sec)

      _ ->
        if heading_stack == [] do
          []
        else
          heading_stack |> Enum.map(& &1.title)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Section accumulation
  # ---------------------------------------------------------------------------

  defp maybe_add_section(sections, [], _current_section), do: sections
  # defp maybe_add_section(sections, nil, _current_section), do: sections

  defp maybe_add_section(sections, content_lines, current_section) when is_list(content_lines) do
    content = content_lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()

    case current_section do
      %Section{type: :heading} = sec ->
        section = %{sec | content: content, tokens: TokenEstimator.estimate(content)}
        [section | sections]

      %Section{} = sec when content != "" ->
        section = %{sec | content: content, tokens: TokenEstimator.estimate(content)}
        [section | sections]

      nil when content != "" ->
        section = %Section{
          id: generate_id(),
          type: :paragraph,
          content: content,
          parent_path: [],
          position: 0,
          tokens: TokenEstimator.estimate(content)
        }

        [section | sections]

      _ ->
        sections
    end
  end

  # ---------------------------------------------------------------------------
  # Chunking
  # ---------------------------------------------------------------------------

  defp chunk_section(section, section_idx) do
    overhead = title_overhead_tokens(section)
    effective_max = max(1, chunk_max_tokens() - overhead)

    if section.tokens <= effective_max do
      [create_chunk(section, section.content, section_idx, 0)]
    else
      split_into_chunks(section, section_idx, effective_max)
    end
  end

  defp split_into_chunks(section, section_idx, effective_max) do
    paragraphs = String.split(section.content, ~r/\n\n+/)

    paragraphs
    |> combine_to_target_size(chunk_min_tokens(), effective_max)
    |> Enum.with_index()
    |> Enum.map(fn {chunk_content, chunk_idx} ->
      create_chunk(section, chunk_content, section_idx, chunk_idx)
    end)
  end

  defp title_overhead_tokens(section) do
    prefix = prepend_title_to_content(section, "")
    if prefix == "", do: 0, else: TokenEstimator.estimate(prefix)
  end

  defp combine_to_target_size(paragraphs, min_tokens, max_tokens) do
    combine_paragraphs(paragraphs, [], [], 0, min_tokens, max_tokens)
  end

  defp combine_paragraphs([], chunks, current, _current_tokens, _min, _max) do
    final_chunks =
      if current != [], do: [Enum.reverse(current) |> Enum.join("\n\n") | chunks], else: chunks

    Enum.reverse(final_chunks)
  end

  defp combine_paragraphs([para | rest], chunks, current, current_tokens, min_tokens, max_tokens) do
    para_tokens = TokenEstimator.estimate(para)
    new_tokens = current_tokens + para_tokens

    cond do
      current == [] && para_tokens > max_tokens ->
        split_chunks = split_large_paragraph(para, max_tokens)
        combine_paragraphs(rest, chunks ++ split_chunks, [], 0, min_tokens, max_tokens)

      current == [] || new_tokens <= max_tokens ->
        combine_paragraphs(rest, chunks, [para | current], new_tokens, min_tokens, max_tokens)

      true ->
        chunk = Enum.reverse(current) |> Enum.join("\n\n")
        combine_paragraphs([para | rest], [chunk | chunks], [], 0, min_tokens, max_tokens)
    end
  end

  defp split_large_paragraph(para, max_tokens) do
    sentences =
      para
      |> String.replace(~r/([.!?])\s+/, "\\1\n")
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    combine_sentences(sentences, [], [], 0, max_tokens)
  end

  defp combine_sentences([], chunks, current, _current_tokens, _max) do
    final_chunks =
      if current != [], do: [Enum.reverse(current) |> Enum.join(" ") | chunks], else: chunks

    Enum.reverse(final_chunks)
  end

  defp combine_sentences([sentence | rest], chunks, current, current_tokens, max_tokens) do
    sentence = String.trim(sentence)
    sentence_tokens = TokenEstimator.estimate(sentence)
    new_tokens = current_tokens + sentence_tokens

    cond do
      current == [] && sentence_tokens > max_tokens ->
        combine_sentences(rest, [sentence | chunks], [], 0, max_tokens)

      current == [] || new_tokens <= max_tokens ->
        combine_sentences(rest, chunks, [sentence | current], new_tokens, max_tokens)

      true ->
        chunk = Enum.reverse(current) |> Enum.join(" ")
        combine_sentences([sentence | rest], [chunk | chunks], [], 0, max_tokens)
    end
  end

  # ---------------------------------------------------------------------------
  # Chunk creation
  # ---------------------------------------------------------------------------

  defp create_chunk(section, content, section_idx, chunk_idx) do
    content_with_title = prepend_title_to_content(section, content)

    %Chunk{
      id: "chunk_#{section_idx}_#{chunk_idx}",
      section_id: section.id,
      content: content_with_title,
      section_path: get_current_path(section),
      tokens: TokenEstimator.estimate(content_with_title),
      metadata: %{
        section_type: section.type,
        section_level: section.level,
        position: section.position
      }
    }
  end

  defp prepend_title_to_content(%Section{type: :heading, level: level, title: title}, content)
       when is_binary(title) and is_integer(level) do
    heading_prefix = String.duplicate("#", level)
    "#{heading_prefix} #{title}\n\n#{content}"
  end

  defp prepend_title_to_content(%Section{type: type, parent_path: parent_path}, content)
       when type in [:table, :figure] and is_list(parent_path) and parent_path != [] do
    parent_title = List.last(parent_path)
    "## #{parent_title}\n\n#{content}"
  end

  defp prepend_title_to_content(_section, content), do: content

  # ---------------------------------------------------------------------------
  # Utilities
  # ---------------------------------------------------------------------------

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp parse_html(_text) do
    raise "HTML parsing not implemented. Please use Floki library and implement parse_html/1"
  end

  defp parse_plain_text(text) do
    text
    |> String.split(~r/\n\n+/)
    |> Enum.with_index()
    |> Enum.map(fn {content, idx} ->
      %Section{
        id: generate_id(),
        type: :paragraph,
        content: String.trim(content),
        parent_path: [],
        position: idx,
        tokens: TokenEstimator.estimate(content)
      }
    end)
    |> Enum.reject(&(&1.content == ""))
  end
end
