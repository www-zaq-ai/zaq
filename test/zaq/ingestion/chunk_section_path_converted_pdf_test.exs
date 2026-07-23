defmodule Zaq.Ingestion.ChunkSectionPathConvertedPdfTest do
  @moduledoc """
  Fixture gate test for the section-chunking rules in
  `docs/exec-plans/active/2026-07-22-chunker-md-section-rules.md`.

  Golden rule: the chunker does not manipulate chunks or their metadata.
  Section paths come exclusively from markdown headings (`#`…`######`);
  chunks pack toward `chunk_max_tokens` without crossing a path boundary;
  tables travel with their context and split at row boundaries with the
  header repeated; every chunk carries source locators.

  Driven by real converter output (`chunk_section_path_converted_pdf.md`,
  an 11-page French council-minutes PDF) through the real
  `parse_layout/2` + `chunk_sections/2` — no stubs.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.DocumentChunker
  alias Zaq.System

  @fixture_path Path.expand("../../fixtures/chunk_section_path_converted_pdf.md", __DIR__)

  # One markdown file per synthetic rule case — cases the real converter
  # fixture structurally cannot express (it has only level-1 headings, no
  # bold/italic lines, and no oversized tables).
  @rules_dir Path.expand("../../fixtures/chunker_rules", __DIR__)

  # The eight real `#` headings of the fixture, verbatim (typographic
  # apostrophes included). Items A, F and G are bullet-titled by the
  # converter (upstream defect) and therefore own no path of their own.
  @title_b "2026-04-B-Vote des taux d’imposition 2026"
  @title_c "2026-04-C-Vote du budget Primitif Commune 2026"
  @title_d "2026-04-D-Vote du budget Primitif CCAS 2026"
  @title_e "E-Modification désignation des délégués au SME compétence Service Public d’Assainissement Non Collectif (S.P.A.N.C) - (1 titulaire et un suppléant)"
  @title_h "2026-04-H-Désignation 1 délégué à l’EPF Auvergne"
  @title_i "2026-04-I-Cession parcelle de terrain chemin de Laspouze suite au déclassement du domaine public à M. JAFFEUX."
  @title_j "2026-04-J-Subvention DRAC devis complémentaires chapelle Sainte Magdeleine"
  @title_ccid "Point d’information : renouvellement commission communale des impôts directs (CCID)"

  @heading_titles [
    @title_b,
    @title_c,
    @title_d,
    @title_e,
    @title_h,
    @title_i,
    @title_j,
    @title_ccid
  ]

  @vote_table_header "|CONTRE|ABSTENTION|POUR|TOTAL|"
  @budget_table_header "|SECTION|DEPENSES|RECETTES|"

  @table_delimiter_re ~r/^\|(?:\s*:?-+:?\s*\|)+\s*$/

  setup do
    source = File.read!(@fixture_path)
    sections = DocumentChunker.parse_layout(source)
    chunks = DocumentChunker.chunk_sections(sections)
    config = System.get_embedding_config()

    %{
      source: source,
      chunks: chunks,
      min: config.chunk_min_tokens,
      max: config.chunk_max_tokens
    }
  end

  # ---------------------------------------------------------------------------
  # Budget (Rules 4–6)
  # ---------------------------------------------------------------------------

  describe "budget" do
    test "packs the fixture into at most 13 chunks", %{chunks: chunks} do
      assert length(chunks) <= 13,
             "expected <= 13 packed chunks, got #{length(chunks)} " <>
               "(spread: #{inspect(Enum.map(chunks, & &1.tokens))})"
    end

    test "no chunk exceeds chunk_max_tokens", %{chunks: chunks, max: max} do
      for chunk <- chunks do
        assert chunk.tokens <= max,
               "chunk #{chunk.id} has #{chunk.tokens} tokens (max #{max})"
      end
    end

    test "under-min chunks only as isolated runs or unmergeable tails", %{
      chunks: chunks,
      min: min,
      max: max
    } do
      chunks
      |> Enum.chunk_by(& &1.section_path)
      |> Enum.each(fn group -> assert_no_fragmentation(group, min, max) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Section paths (golden rule + Rule 2)
  # ---------------------------------------------------------------------------

  describe "section paths" do
    test "derive exclusively from the markdown headings", %{chunks: chunks} do
      expected = MapSet.new([[] | Enum.map(@heading_titles, &[&1])])
      actual = chunks |> Enum.map(& &1.section_path) |> MapSet.new()

      assert actual == expected,
             "invented or missing paths: " <>
               inspect(MapSet.symmetric_difference(actual, expected))
    end

    test "file all pre-heading content (pages 1–4) under the empty path", %{chunks: chunks} do
      # Attendance table, agenda, huis-clos votes, and item A's bullet body
      # all precede the first `#` heading — no heading means no section path.
      for marker <- [
            "NOM & PRENOM",
            "Ordre du jour :",
            "L.2123-20 à L.2123-24",
            "2026-04-A-Indemnités maires et adjoints"
          ] do
        owners = chunks_containing(chunks, marker)
        assert owners != [], "no chunk contains #{inspect(marker)}"

        for chunk <- owners do
          assert chunk.section_path == [],
                 "preamble content #{inspect(marker)} filed under #{inspect(chunk.section_path)}"
        end
      end
    end

    test "keep the agenda `- o` bullets in the preamble", %{chunks: chunks} do
      assert [chunk | _] = chunks_containing(chunks, "- o " <> @title_c)
      assert chunk.section_path == []
    end

    test "file bullet-titled items F and G under item E's heading (accepted upstream defect)",
         %{chunks: chunks} do
      # Unique body strings — never the titles: the agenda repeats every title.
      f_body = "M. Christophe BRERAT, délégué titulaire et M. Frédéric PERRIN"
      g_body = "Secteur Intercommunal d’Energie"

      for marker <- [f_body, g_body] do
        owners = chunks_containing(chunks, marker)
        assert owners != [], "no chunk contains #{inspect(marker)}"

        for chunk <- owners do
          assert chunk.section_path == [@title_e]
        end
      end
    end

    test "keep heading lines verbatim in chunk content", %{chunks: chunks} do
      for title <- @heading_titles do
        owners = chunks_containing(chunks, "# " <> title)
        assert owners != [], "heading line for #{inspect(title)} missing from all chunks"

        for chunk <- owners do
          assert chunk.section_path == [title]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tables (Rule 3)
  # ---------------------------------------------------------------------------

  describe "tables" do
    test "no chunk consists solely of table rows", %{chunks: chunks} do
      for chunk <- chunks do
        lines = meaningful_lines(chunk.content)

        refute Enum.all?(lines, &String.starts_with?(&1, "|")),
               "chunk #{chunk.id} is table-rows-only:\n#{chunk.content}"
      end
    end

    test "every chunk containing table rows also contains a table header block", %{
      chunks: chunks
    } do
      for chunk <- chunks do
        lines = meaningful_lines(chunk.content)

        if Enum.any?(lines, &String.starts_with?(&1, "|")) do
          assert Enum.any?(lines, &Regex.match?(@table_delimiter_re, &1)),
                 "chunk #{chunk.id} has orphan table rows without a header/delimiter:\n" <>
                   chunk.content
        end
      end
    end

    test "every vote table shares its chunk with the Vote/Adopté context", %{chunks: chunks} do
      owners = chunks_containing(chunks, @vote_table_header)
      assert owners != []

      for chunk <- owners do
        assert String.contains?(chunk.content, "Vote :"),
               "vote table in chunk #{chunk.id} lost its `Vote :` lead-in"

        assert String.contains?(chunk.content, "Adopté"),
               "vote table in chunk #{chunk.id} lost its `Adopté` outcome"
      end
    end

    test "the repeated budget tables land under their own owning paths", %{chunks: chunks} do
      owners = chunks_containing(chunks, @budget_table_header)

      assert owners |> Enum.map(& &1.section_path) |> MapSet.new() ==
               MapSet.new([[@title_c], [@title_d]])

      for chunk <- chunks_containing(chunks, "964 708,70") do
        assert chunk.section_path == [@title_c]
      end

      for chunk <- chunks_containing(chunks, "5 355,50") do
        assert chunk.section_path == [@title_d]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Content preservation (golden rule)
  # ---------------------------------------------------------------------------

  describe "content preservation" do
    test "every meaningful source line survives into exactly one chunk, in order", %{
      source: source,
      chunks: chunks
    } do
      source_lines = meaningful_lines(source)
      chunk_lines = Enum.flat_map(chunks, &meaningful_lines(&1.content))

      assert chunk_lines == source_lines
    end
  end

  # ---------------------------------------------------------------------------
  # Locators (Rules 1 & 7)
  # ---------------------------------------------------------------------------

  describe "locators" do
    test "page markers never appear in chunk content", %{chunks: chunks} do
      for chunk <- chunks do
        refute String.contains?(chunk.content, "<!-- page:")
      end
    end

    test "every chunk carries ordered page/line locators", %{chunks: chunks} do
      for chunk <- chunks do
        assert is_integer(chunk.start_page) and is_integer(chunk.end_page)
        assert is_integer(chunk.start_line) and is_integer(chunk.end_line)
        assert chunk.start_page <= chunk.end_page
        assert chunk.start_line <= chunk.end_line
      end
    end

    test "chunks stay in document order with monotonic pages and lines", %{chunks: chunks} do
      lines = Enum.map(chunks, & &1.start_line)
      assert lines == Enum.sort(lines)
      assert lines == Enum.uniq(lines)

      pages = Enum.map(chunks, & &1.start_page)
      assert pages == Enum.sort(pages)
    end

    test "the fixture spans pages 1 through 11", %{chunks: chunks} do
      assert List.first(chunks).start_page == 1
      assert List.last(chunks).end_page == 11
    end
  end

  # ---------------------------------------------------------------------------
  # Golden rule — synthetic documents
  # ---------------------------------------------------------------------------

  describe "golden rule (synthetic)" do
    test "no headings means no section path" do
      chunks = chunk!(rules_fixture("no_headings.md"))
      assert chunks != []

      for chunk <- chunks do
        assert chunk.section_path == []
        refute String.contains?(chunk.content, "<!-- page:")
      end
    end

    test "bold and italic lines are never promoted to headings" do
      chunks = chunk!(rules_fixture("bold_italic_promotion.md"))

      assert chunks |> Enum.map(& &1.section_path) |> Enum.uniq() == [["Réel"]]

      for chunk <- chunks, path_entry <- chunk.section_path do
        refute String.contains?(path_entry, "Overview")
        refute String.contains?(path_entry, "Details")
      end
    end

    test "deliberation-id bullets are never promoted to headings" do
      chunks = chunk!(rules_fixture("deliberation_bullet.md"))

      assert chunks |> Enum.map(& &1.section_path) |> Enum.uniq() == [["Réel"]]
    end
  end

  # ---------------------------------------------------------------------------
  # Heading nesting (Rule 2, edge-case defaults)
  # ---------------------------------------------------------------------------

  describe "heading nesting (synthetic)" do
    test "h1–h6 nest into the path and level skips stay literal" do
      chunks = chunk!(rules_fixture("heading_nesting.md"))

      assert owning_path(chunks, "Texte beta.") == ["Alpha", "Beta"]
      assert owning_path(chunks, "Texte delta.") == ["Alpha", "Beta", "Delta"]
      assert owning_path(chunks, "Texte zeta.") == ["Alpha", "Beta", "Delta", "Zeta"]
    end
  end

  # ---------------------------------------------------------------------------
  # Oversized content (Rule 5)
  # ---------------------------------------------------------------------------

  describe "oversized content (synthetic)" do
    test "a body exceeding max splits into budgeted chunks under one path" do
      chunks = chunk!(rules_fixture("oversized_body.md"))
      max = System.get_embedding_config().chunk_max_tokens

      assert length(chunks) >= 2

      for chunk <- chunks do
        assert chunk.section_path == ["Long"]
        assert chunk.tokens <= max
      end
    end

    test "a table exceeding max splits at row boundaries with the header repeated" do
      header = "|Colonne un|Colonne deux|Colonne trois|"

      md = rules_fixture("oversized_table.md")
      chunks = chunk!(md)
      max = System.get_embedding_config().chunk_max_tokens

      assert length(chunks) >= 2

      for chunk <- chunks do
        assert chunk.tokens <= max,
               "table part #{chunk.id} exceeds max (#{chunk.tokens} tokens)"

        lines = meaningful_lines(chunk.content)
        data_index = Enum.find_index(lines, &String.contains?(&1, "cellule"))

        if data_index do
          preceding = Enum.take(lines, data_index)

          assert header in preceding,
                 "chunk #{chunk.id} holds data rows without the repeated header row"

          assert Enum.any?(preceding, &Regex.match?(@table_delimiter_re, &1)),
                 "chunk #{chunk.id} holds data rows without the delimiter row"
        end
      end

      # No row lost, none duplicated, none split mid-row.
      for i <- 1..250 do
        row = "|cellule #{i} alpha|cellule #{i} beta|cellule #{i} gamma|"
        assert length(chunks_containing(chunks, row)) == 1, "row #{i} lost or duplicated"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Table packing (Rule 3, edge-case defaults)
  # ---------------------------------------------------------------------------

  describe "table packing (synthetic)" do
    test "a small table packs into the same chunk as its surrounding section" do
      chunks = chunk!(rules_fixture("table_packs_small.md"))

      assert [chunk] = chunks
      assert String.contains?(chunk.content, "Vote :")
      assert String.contains?(chunk.content, "|CONTRE|")
      assert String.contains?(chunk.content, "Adopté")
    end

    test "a table that cannot fit moves whole to the next chunk with its glue blocks" do
      chunks = chunk!(rules_fixture("table_moves_whole.md"))
      max = System.get_embedding_config().chunk_max_tokens

      assert length(chunks) >= 2

      for chunk <- chunks do
        assert chunk.tokens <= max
      end

      [table_chunk] = chunks_containing(chunks, "|CONTRE|")
      assert String.contains?(table_chunk.content, "Vote :")
      assert String.contains?(table_chunk.content, "Adopté")
      refute String.contains?(table_chunk.content, "remplissage1 ")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp chunk!(markdown) do
    markdown
    |> DocumentChunker.parse_layout()
    |> DocumentChunker.chunk_sections()
  end

  defp chunks_containing(chunks, text) do
    Enum.filter(chunks, &String.contains?(&1.content, text))
  end

  defp owning_path(chunks, text) do
    case chunks_containing(chunks, text) do
      [chunk | _] -> chunk.section_path
      [] -> flunk("no chunk contains #{inspect(text)}")
    end
  end

  defp meaningful_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn line -> line == "" or String.starts_with?(line, "<!--") end)
  end

  defp rules_fixture(name) do
    File.read!(Path.join(@rules_dir, name))
  end

  defp assert_no_fragmentation(group, min, max) do
    last_index = length(group) - 1

    group
    |> Enum.with_index()
    |> Enum.each(fn {chunk, index} ->
      cond do
        chunk.tokens >= min ->
          :ok

        last_index == 0 ->
          # Isolated run genuinely holding less than chunk_min_tokens.
          :ok

        index == last_index ->
          previous = Enum.at(group, index - 1)

          assert previous.tokens + chunk.tokens > max,
                 "under-min tail #{chunk.id} (#{chunk.tokens} tokens) could have " <>
                   "merged into #{previous.id} (#{previous.tokens} tokens)"

        true ->
          flunk(
            "under-min chunk #{chunk.id} (#{chunk.tokens} tokens) is fragmentation " <>
              "inside a #{inspect(chunk.section_path)} run"
          )
      end
    end)
  end
end
