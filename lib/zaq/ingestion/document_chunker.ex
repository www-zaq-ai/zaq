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
    @moduledoc "Represents a document section with metadata and source locators."
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
      :tokens,
      # source locators (annotated post-parse; pages driven by <!-- page: N -->)
      :start_page,
      :end_page,
      :start_line,
      :end_line,
      :start_offset,
      :end_offset,
      # source line entries backing content's meaningful lines, in order —
      # each %{line, page, text, start, stop} (character offsets)
      :source_lines
    ]
  end

  defmodule Chunk do
    @moduledoc """
    Represents a chunk with metadata.

    Invariants:

      * `content` carries the source's lines verbatim, but is not a
        byte-exact slice: packed sections are joined with `"\n\n"`, page
        markers are stripped, and a row-split table part repeats its header
        row. The `start_*`/`end_*` fields are a source **locator** — the
        span `[start_offset, end_offset)` (character offsets) contains the
        chunk's lines plus any stripped markers/blank runs; it does not
        equal `content`.
      * `embedding_input` is the embed-only enrichment, built from exactly
        two fields and nothing else (no `metadata`, no document identifiers):

            Enum.join(section_path, " > ") <> "\n\n" <> content

        The prefix is omitted entirely when `section_path` is empty or the
        prefix alone would consume the whole chunk token budget (see
        `context_prefix/1`). It is transient: sent to the embedding model,
        never persisted, FTS-indexed, or shown to users — the stored
        embedding vector is therefore a pure function of `content` and
        `section_path`, and changing this derivation invalidates all
        previously stored vectors (requires a re-embed migration).
    """
    defstruct [
      :id,
      :section_id,
      :content,
      # ["Chapter 1", "Section 1.1", "Subsection 1.1.1"]
      :section_path,
      :tokens,
      :metadata,
      # transient — embed only, never persisted (see moduledoc)
      :embedding_input,
      # source locators (see moduledoc: locator, not a slice)
      :start_page,
      :end_page,
      :start_line,
      :end_line,
      :start_offset,
      :end_offset
    ]

    @doc """
    The text sent to the embedding model for `content` chunked under
    `section_path`.

    Pure derivation shared by the chunker and `IngestChunkWorker` (which
    rebuilds it from the queued payload's `"section_path"` + `"content"`).
    An empty path means no prefix at all, and a prefix whose token overhead
    would consume the whole chunk budget is omitted — the prefix alone must
    never push `embedding_input` past `chunk_max_tokens`.
    """
    def embedding_input(content, section_path) when is_binary(content) do
      context_prefix(section_path) <> content
    end

    @doc """
    The section-path context prefix (with trailing separator) used by
    `embedding_input/2`, or `""` when there is no usable prefix.
    """
    def context_prefix([]), do: ""

    def context_prefix(section_path) when is_list(section_path) do
      prefix = Enum.join(section_path, " > ") <> "\n\n"

      if TokenEstimator.estimate(prefix) >= chunk_max_tokens() do
        ""
      else
        prefix
      end
    end

    defp chunk_max_tokens do
      Zaq.System.get_embedding_config().chunk_max_tokens
    end
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
        :markdown -> text |> parse_markdown() |> annotate_source_positions(text)
        :html -> parse_html(text)
        :text -> text |> parse_plain_text() |> annotate_source_positions(text)
        _ -> {:error, {:invalid_format, format}}
      end
    end
  end

  @doc """
  Chunk sections into token-bounded pieces.

  Runs of consecutive sections sharing a `section_path` are packed
  together toward `chunk_max_tokens`; packing never crosses a path
  boundary. Tables travel with their surrounding blocks and split at row
  boundaries (header repeated) only when they exceed the budget on their
  own. Every chunk carries source locators — the span locates the chunk
  in the source, it is not a byte-exact slice.

  Min/max token sizes are read from `config :zaq, Zaq.Ingestion`.
  """
  def chunk_sections(sections, _opts \\ []) when is_list(sections) do
    sections
    |> Enum.filter(fn section ->
      String.trim(section.content || "") != ""
    end)
    |> Enum.chunk_by(&get_current_path/1)
    |> Enum.flat_map(&chunk_path_run/1)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} -> %{chunk | id: "chunk_#{index}"} end)
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
      heading = parse_heading(line) ->
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

  defp handle_heading(
         line,
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
    # Seed the section's content with the verbatim heading line so the
    # source heading is never removed from the corpus; heading-only
    # sections stay non-empty and survive chunk_sections/2.
    parse_markdown_lines(rest, sections, [line], new_section, new_stack, position + 1)
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
    [_, filename] = Regex.run(~r/\[Image:\s*([^\]]+)\]/, line)
    String.trim(filename)
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

  # ---------------------------------------------------------------------------
  # Heading parser
  # ---------------------------------------------------------------------------

  # Golden rule: markdown `#`…`######` headings are the ONLY source of
  # structure. The chunker never promotes bold/italic lines, bullets, or
  # id patterns to headings — structure defects in the markdown are
  # converter bugs, fixed upstream.
  defp parse_heading(line) do
    case Regex.run(~r/^(#+)\s+(.+)$/, line) do
      [_, hashes, title] -> {String.length(hashes), String.trim(title)}
      nil -> nil
    end
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
  # Chunking — cross-section packing (Rules 3–6)
  # ---------------------------------------------------------------------------

  @section_separator "\n\n"

  # A run is a maximal list of consecutive sections sharing one path.
  # Pieces (packable fragments carrying their source-line entries) are
  # packed greedily toward the effective max; tables glue to one block on
  # each side and row-split with the header repeated when oversized.
  defp chunk_path_run([first | _] = run) do
    path = get_current_path(first)
    effective_max = effective_max_tokens(path)

    run
    |> Enum.flat_map(&section_pieces(&1, effective_max))
    |> glue_tables()
    |> Enum.flat_map(&fit_unit(&1, effective_max))
    |> pack_units(effective_max)
    |> merge_undersized(chunk_min_tokens(), effective_max)
    |> Enum.map(&build_chunk(&1, path))
  end

  # Budget so that embedding_input (prefix + content) stays under
  # chunk_max_tokens; the prefix itself never eats the whole budget
  # (Chunk.context_prefix/1 collapses to "" in that case).
  defp effective_max_tokens(path) do
    overhead = TokenEstimator.estimate(Chunk.context_prefix(path))
    max(1, chunk_max_tokens() - overhead)
  end

  # ---------------------------------------------------------------------------
  # Pieces — packable fragments of a section
  # ---------------------------------------------------------------------------

  defp piece(section, text, entries) do
    %{
      section: section,
      type: section.type,
      text: text,
      entries: entries,
      tokens: TokenEstimator.estimate(text)
    }
  end

  # Tables stay atomic pieces; other sections explode into blocks so the
  # packer can fill chunks densely. Entries distribute positionally: a
  # section's meaningful content lines map 1:1, in order, onto its
  # source_lines.
  defp section_pieces(%Section{type: :table} = section, _effective_max) do
    [piece(section, section.content, section.source_lines || [])]
  end

  defp section_pieces(section, effective_max) do
    section.content
    |> String.split(~r/\n\n+/)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> distribute_entries(section.source_lines || [])
    |> Enum.flat_map(fn {block, entries} ->
      split_oversized_block(section, block, entries, effective_max)
    end)
  end

  defp distribute_entries(blocks, entries) do
    {pairs, _rest} =
      Enum.map_reduce(blocks, entries, fn block, remaining ->
        {taken, rest} = Enum.split(remaining, length(meaningful_lines(block)))
        {{block, taken}, rest}
      end)

    pairs
  end

  # A single block over budget splits at sentence boundaries; the parts
  # share the block's source span (a locator, not a slice).
  defp split_oversized_block(section, block, entries, effective_max) do
    if TokenEstimator.estimate(block) <= effective_max do
      [piece(section, block, entries)]
    else
      block
      |> split_large_paragraph(effective_max)
      |> Enum.map(&piece(section, &1, entries))
    end
  end

  # ---------------------------------------------------------------------------
  # Table glue and row-splitting (Rule 3)
  # ---------------------------------------------------------------------------

  # A table glues to the block immediately before it and the block
  # immediately after it; the glued unit is atomic for packing.
  defp glue_tables(pieces) do
    pieces
    |> Enum.reduce({[], false}, fn piece, {units, glue_next?} ->
      cond do
        piece.type == :table and units != [] ->
          [current | rest] = units
          {[current ++ [piece] | rest], true}

        piece.type == :table ->
          {[[piece]], true}

        glue_next? ->
          [current | rest] = units
          {[current ++ [piece] | rest], false}

        true ->
          {[[piece] | units], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # A unit over budget row-splits its oversized tables (the preceding
  # block's tokens are budgeted into the first part so the glue survives),
  # then repacks its pieces greedily.
  defp fit_unit(unit, effective_max) do
    if unit_tokens(unit) <= effective_max do
      [unit]
    else
      unit
      |> row_split_oversized_tables(effective_max)
      |> Enum.map(&[&1])
      |> pack_units(effective_max)
    end
  end

  defp row_split_oversized_tables(pieces, effective_max) do
    pieces
    |> Enum.reduce({[], 0}, fn piece, {acc, prev_tokens} ->
      if piece.type == :table and piece.tokens > effective_max do
        first_budget = max(1, effective_max - prev_tokens)
        parts = row_split(piece, first_budget, effective_max)
        {Enum.reverse(parts, acc), 0}
      else
        {[piece | acc], piece.tokens}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Splits a table at row boundaries. Every continuation part repeats the
  # header + delimiter rows (so no part holds orphan rows), but only the
  # part's own source rows back its locator entries — the repeated header
  # has no source position of its own.
  defp row_split(piece, first_budget, effective_max) do
    [header_line, delimiter_line | rows] = String.split(piece.text, "\n")
    rows = Enum.reject(rows, &(String.trim(&1) == ""))
    {header_entries, row_entries} = Enum.split(piece.entries, 2)

    head = header_line <> "\n" <> delimiter_line

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} -> {row, Enum.at(row_entries, index)} end)
    |> chunk_rows(head, first_budget, effective_max)
    |> Enum.with_index()
    |> Enum.map(fn {{text, entries}, index} ->
      entries = if index == 0, do: header_entries ++ entries, else: entries
      %{piece | text: text, entries: entries, tokens: TokenEstimator.estimate(text)}
    end)
  end

  defp chunk_rows(rows_with_entries, head, first_budget, effective_max) do
    {parts, current, _budget} =
      Enum.reduce(rows_with_entries, {[], [], first_budget}, fn pair, {parts, current, budget} ->
        candidate = part_text(head, Enum.reverse([pair | current]))

        cond do
          current == [] ->
            {parts, [pair], budget}

          TokenEstimator.estimate(candidate) <= budget ->
            {parts, [pair | current], budget}

          true ->
            {[Enum.reverse(current) | parts], [pair], effective_max}
        end
      end)

    parts = if current == [], do: parts, else: [Enum.reverse(current) | parts]

    parts
    |> Enum.reverse()
    |> Enum.map(fn pairs ->
      entries = pairs |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)
      {part_text(head, pairs), entries}
    end)
  end

  defp part_text(head, pairs) do
    head <> "\n" <> Enum.map_join(pairs, "\n", &elem(&1, 0))
  end

  # ---------------------------------------------------------------------------
  # Packing (Rules 4–6)
  # ---------------------------------------------------------------------------

  # Greedy packing of atomic units toward the effective max. The budget is
  # measured on the joined candidate string — never the sum of per-piece
  # estimates — so a packed group can never exceed the budget.
  defp pack_units(units, effective_max) do
    {groups, current} =
      Enum.reduce(units, {[], []}, fn unit, {groups, current} ->
        cond do
          current == [] ->
            {groups, unit}

          group_tokens(current ++ unit) <= effective_max ->
            {groups, current ++ unit}

          true ->
            {[current | groups], unit}
        end
      end)

    groups = if current == [], do: groups, else: [current | groups]
    Enum.reverse(groups)
  end

  # An under-min group merges into its neighbor whenever the merged result
  # still fits; under-min chunks survive only for genuinely short runs.
  defp merge_undersized(groups, min, effective_max) do
    groups
    |> Enum.reduce([], &merge_group(&1, &2, min, effective_max))
    |> Enum.reverse()
  end

  defp merge_group(group, [], _min, _effective_max), do: [group]

  defp merge_group(group, [previous | rest] = acc, min, effective_max) do
    if (group_tokens(group) < min or group_tokens(previous) < min) and
         group_tokens(previous ++ group) <= effective_max do
      [previous ++ group | rest]
    else
      [group | acc]
    end
  end

  defp group_tokens(pieces) do
    pieces
    |> Enum.map_join(@section_separator, & &1.text)
    |> TokenEstimator.estimate()
  end

  defp unit_tokens(unit), do: group_tokens(unit)

  # Splits on the pattern, pairing every piece with the verbatim separator
  # that followed it in the source ("" for the last), so pieces combined
  # into one chunk rejoin byte-exactly.
  defp split_preserving_separators(text, pattern) do
    text
    |> String.split(pattern, include_captures: true)
    |> pair_with_separators()
  end

  defp pair_with_separators([]), do: []
  defp pair_with_separators([piece]), do: [{piece, ""}]
  defp pair_with_separators([piece, sep | rest]), do: [{piece, sep} | pair_with_separators(rest)]

  # Rejoins {piece, separator} pairs (accumulated in reverse) into the
  # byte-exact source slice. The final piece's trailing separator is
  # dropped — it lies between two chunks, inside neither.
  defp join_pairs([{last, _sep_after_chunk} | earlier]) do
    Enum.reduce(earlier, last, fn {piece, sep}, acc -> piece <> sep <> acc end)
  end

  defp split_large_paragraph(para, max_tokens) do
    para
    |> split_preserving_separators(~r/(?<=[.!?])\s+/)
    |> combine_sentences([], [], 0, max_tokens)
  end

  defp combine_sentences([], chunks, current, _current_tokens, _max) do
    final_chunks = if current != [], do: [join_pairs(current) | chunks], else: chunks

    Enum.reverse(final_chunks)
  end

  defp combine_sentences(
         [{sentence, _sep} = pair | rest],
         chunks,
         current,
         current_tokens,
         max_tokens
       ) do
    sentence_tokens = TokenEstimator.estimate(sentence)
    new_tokens = current_tokens + sentence_tokens

    cond do
      current == [] && sentence_tokens > max_tokens ->
        # A single sentence over the budget is accepted as-is (see plan
        # Edge cases) — its trailing separator is dropped like any other
        # chunk boundary.
        combine_sentences(rest, [sentence | chunks], [], 0, max_tokens)

      current == [] || new_tokens <= max_tokens ->
        combine_sentences(rest, chunks, [pair | current], new_tokens, max_tokens)

      true ->
        chunk = join_pairs(current)
        combine_sentences([pair | rest], [chunk | chunks], [], 0, max_tokens)
    end
  end

  # ---------------------------------------------------------------------------
  # Chunk creation
  # ---------------------------------------------------------------------------

  defp build_chunk(pieces, section_path) do
    content = Enum.map_join(pieces, @section_separator, & &1.text)
    entries = Enum.flat_map(pieces, & &1.entries)
    first = List.first(entries)
    last = List.last(entries)
    section = hd(pieces).section

    %Chunk{
      # id assigned by chunk_sections/2 once all runs are flattened
      id: nil,
      section_id: section.id,
      content: content,
      section_path: section_path,
      embedding_input: Chunk.embedding_input(content, section_path),
      tokens: TokenEstimator.estimate(content),
      metadata: %{
        section_type: section.type,
        section_level: section.level,
        position: section.position
      },
      start_page: first && first.page,
      end_page: last && last.page,
      start_line: first && first.line,
      end_line: last && last.line,
      start_offset: first && first.start,
      end_offset: last && last.stop
    }
  end

  # ---------------------------------------------------------------------------
  # Source-position annotation (Rules 1 & 7)
  # ---------------------------------------------------------------------------

  @page_marker ~r/^<!--\s*page:\s*(\d+)\s*-->$/

  # Builds a source line table (character offsets; pages driven by the
  # <!-- page: N --> markers) and gives every section its span. Matching is
  # whole-line equality behind a monotonic cursor — substring search would
  # mismatch: the corpus repeats many lines verbatim.
  defp annotate_source_positions(sections, source) do
    {annotated, _remaining} =
      Enum.map_reduce(sections, build_line_entries(source), fn section, remaining ->
        {entries, rest} = take_section_entries(section, remaining)
        {apply_span(section, entries), rest}
      end)

    annotated
  end

  defp build_line_entries(source) do
    source
    |> String.split("\n")
    |> Enum.map_reduce({1, 0, 1}, fn line, {line_no, offset, page} ->
      text = String.trim(line)

      page =
        case Regex.run(@page_marker, text) do
          [_, number] -> String.to_integer(number)
          nil -> page
        end

      line_length = String.length(line)

      entry =
        if text == "" or String.starts_with?(text, "<!--") do
          nil
        else
          %{line: line_no, page: page, text: text, start: offset, stop: offset + line_length}
        end

      {entry, {line_no + 1, offset + line_length + 1, page}}
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  defp take_section_entries(section, remaining) do
    {taken, rest} =
      section.content
      |> meaningful_lines()
      |> Enum.reduce({[], remaining}, fn line, {taken, rest} ->
        case Enum.split_while(rest, &(&1.text != line)) do
          {_skipped, [match | after_match]} -> {[match | taken], after_match}
          {_all, []} -> {taken, rest}
        end
      end)

    {Enum.reverse(taken), rest}
  end

  defp apply_span(section, []), do: %{section | source_lines: []}

  defp apply_span(section, entries) do
    first = hd(entries)
    last = List.last(entries)

    %{
      section
      | source_lines: entries,
        start_page: first.page,
        end_page: last.page,
        start_line: first.line,
        end_line: last.line,
        start_offset: first.start,
        end_offset: last.stop
    }
  end

  defp meaningful_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn line -> line == "" or String.starts_with?(line, "<!--") end)
  end

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
