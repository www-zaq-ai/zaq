defmodule Zaq.Ingestion.DocumentChunkerTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.TokenEstimator
  alias Zaq.Ingestion.DocumentChunker
  alias Zaq.Ingestion.DocumentChunker.{Chunk, Section}
  alias Zaq.System

  # ---------------------------------------------------------------------------
  # parse_layout/2 — basics
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 basics" do
    test "returns empty list for blank input" do
      assert DocumentChunker.parse_layout("") == []
      assert DocumentChunker.parse_layout("   ") == []
      assert DocumentChunker.parse_layout("\n\n") == []
    end

    test "returns error on unsupported format" do
      assert {:error, {:invalid_format, :pdf}} =
               DocumentChunker.parse_layout("hello", format: :pdf)
    end
  end

  # ---------------------------------------------------------------------------
  # parse_layout/2 — markdown headings
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 markdown headings" do
    test "parses standard markdown headings" do
      md = "# Title\n\nSome content.\n\n## Subtitle\n\nMore content."
      sections = DocumentChunker.parse_layout(md)

      titles = Enum.map(sections, & &1.title)
      assert "Title" in titles
      assert "Subtitle" in titles
    end

    test "assigns correct heading levels" do
      md = "# H1\n\ntext\n\n## H2\n\ntext\n\n### H3\n\ntext"
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))
      levels = Enum.map(headings, & &1.level)
      assert levels == [1, 2, 3]
    end

    test "builds parent_path for nested headings" do
      md = "# Chapter\n\n## Section\n\nContent under section."
      sections = DocumentChunker.parse_layout(md)

      section_heading = Enum.find(sections, &(&1.title == "Section"))
      assert section_heading.parent_path == ["Chapter"]
    end

    test "parses bold-style numbered headings" do
      md = "**1.** **Introduction**\n\nSome intro text."
      sections = DocumentChunker.parse_layout(md)

      heading = Enum.find(sections, &(&1.type == :heading))
      assert heading != nil
      assert heading.level == 1
    end

    test "parses italic-style numbered headings" do
      md = "_1.1_ _Details_\n\nSome details."
      sections = DocumentChunker.parse_layout(md)

      heading = Enum.find(sections, &(&1.type == :heading))
      assert heading != nil
      assert heading.level == 2
    end

    test "parses simple bold heading as level 2" do
      md = "**Overview**\n\nSome details."
      sections = DocumentChunker.parse_layout(md)

      heading = Enum.find(sections, &(&1.type == :heading))
      assert heading != nil
      assert heading.level == 2
      assert heading.title == "Overview"
    end

    test "parses simple italic heading as level 3" do
      md = "_Overview_\n\nSome details."
      sections = DocumentChunker.parse_layout(md)

      heading = Enum.find(sections, &(&1.type == :heading))
      assert heading != nil
      assert heading.level == 3
      assert heading.title == "Overview"
    end

    test "skips bold TOC entries" do
      md = "**Introduction** **3**\n\nRegular paragraph."
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))
      assert headings == []
    end

    test "skips numbered bold heading lines ending with TOC index" do
      md = "**1.** **Introduction** **3**\n\nRegular paragraph."
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))
      assert headings == []
    end

    test "parses bold two-level numbered heading as level 2" do
      md = "**1.2** **Details**\n\nSection content."
      sections = DocumentChunker.parse_layout(md)

      heading = Enum.find(sections, &(&1.type == :heading))
      assert heading != nil
      assert heading.level == 2
      assert heading.title == "1.2 Details"
    end

    test "parses bold three-level numbered heading as level 3" do
      md = "**1.2.3** **Sub-Details**\n\nSection content."
      sections = DocumentChunker.parse_layout(md)

      heading = Enum.find(sections, &(&1.type == :heading))

      assert heading != nil,
             "**1.2.3** **Sub-Details** should produce a heading but got nil (three-level bold numbering silently dropped)"

      assert heading.level == 3
      assert heading.title == "1.2.3 Sub-Details"
    end

    test "skips italic numbered TOC entry ending with page number" do
      md = "_1.2_ _Introduction_ _3_\n\nRegular paragraph."
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))
      assert headings == []
    end

    test "parses deepest supported italic numbering deterministically" do
      md = "_1.2.3_ _Deep Details_\n\nBody content."
      sections = DocumentChunker.parse_layout(md)

      heading = Enum.find(sections, &(&1.type == :heading))
      assert heading != nil
      assert heading.level == 3
      assert heading.level <= 6
      assert heading.title == "1.2.3 Deep Details"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_layout/2 — tables
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 tables" do
    test "detects markdown tables as :table sections" do
      md = """
      # Data

      | Name  | Value |
      |-------|-------|
      | Alice | 100   |
      | Bob   | 200   |
      """

      sections = DocumentChunker.parse_layout(md)
      tables = Enum.filter(sections, &(&1.type == :table))
      assert length(tables) == 1
      assert String.contains?(hd(tables).content, "Alice")
    end

    test "single pipe line is not treated as a table" do
      md = "# Heading\n\n| not a table"
      sections = DocumentChunker.parse_layout(md)
      tables = Enum.filter(sections, &(&1.type == :table))
      assert tables == []
    end

    test "keeps table parsing across blank lines inside table block" do
      md = "# Data\n\n| Name | Value |\n|------|-------|\n| A    | 1     |\n\n| B    | 2     |\n"

      sections = DocumentChunker.parse_layout(md)
      [table] = Enum.filter(sections, &(&1.type == :table))

      assert String.contains?(table.content, "| A    | 1     |")
      assert String.contains?(table.content, "| B    | 2     |")
    end

    test "terminates table when blank line is followed by non-table content" do
      md = """
      | Name | Value |
      |------|-------|
      | A    | 1     |

      This paragraph must not be included in table content.
      """

      sections = DocumentChunker.parse_layout(md)
      [table] = Enum.filter(sections, &(&1.type == :table))
      [paragraph] = Enum.filter(sections, &(&1.type == :paragraph))

      refute String.contains?(table.content, "must not be included")
      assert String.contains?(paragraph.content, "must not be included")
    end

    test "table at document root keeps empty parent_path" do
      md = "| Col A | Col B |\n|-------|-------|\n| 1     | 2     |"
      sections = DocumentChunker.parse_layout(md)

      [table] = Enum.filter(sections, &(&1.type == :table))
      assert table.parent_path == []
    end

    test "table followed by trailing blank line at end of document is still captured" do
      # Exercises the handle_empty_line_in_table/4 branch where rest == []
      md = "| Name | Value |\n|------|-------|\n| A    | 1     |\n"
      sections = DocumentChunker.parse_layout(md)

      tables = Enum.filter(sections, &(&1.type == :table))
      assert length(tables) == 1
      assert String.contains?(hd(tables).content, "| A    | 1     |")
    end
  end

  # ---------------------------------------------------------------------------
  # parse_layout/2 — figures
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 figures" do
    test "detects markdown image as :figure" do
      md = "# Images\n\n![A cat](cat.png)"
      sections = DocumentChunker.parse_layout(md)

      figures = Enum.filter(sections, &(&1.type == :figure))
      assert length(figures) == 1
      assert hd(figures).title == "A cat"
    end

    test "skips empty-caption PDF placeholders" do
      md = "# Doc\n\n![](something.pdf-page1.png)"
      sections = DocumentChunker.parse_layout(md)

      figures = Enum.filter(sections, &(&1.type == :figure))
      assert figures == []
    end

    test "keeps empty-caption non-pdf image as figure" do
      md = "# Doc\n\n![](something.png)"
      sections = DocumentChunker.parse_layout(md)

      [figure] = Enum.filter(sections, &(&1.type == :figure))
      assert figure.title == ""
      assert figure.content == "![](something.png)"
    end

    test "detects vision image blocks as :figure" do
      md = """
      # Report

      > **[Image: chart.png]**
      > This chart shows revenue growth over Q1-Q4.
      """

      sections = DocumentChunker.parse_layout(md)
      figures = Enum.filter(sections, &(&1.type == :figure))
      assert length(figures) == 1
      assert hd(figures).title == "chart.png"
    end

    test "vision image block stops on blank and keeps following heading separate" do
      md = """
      > **[Image: chart.png]**
      > Revenue trend line for Q1.

      ## Next Section

      Body text.
      """

      sections = DocumentChunker.parse_layout(md)
      [figure] = Enum.filter(sections, &(&1.type == :figure))
      [heading] = Enum.filter(sections, &(&1.type == :heading && &1.title == "Next Section"))

      assert String.contains?(figure.content, "Revenue trend line")
      refute String.contains?(figure.content, "Next Section")
      assert heading.level == 2
    end

    test "vision image block stops when a table starts" do
      md = """
      > **[Image: chart.png]**
      > Description line.
      | Col | Value |
      |-----|-------|
      | A   | 1     |
      """

      sections = DocumentChunker.parse_layout(md)
      [figure] = Enum.filter(sections, &(&1.type == :figure))
      [table] = Enum.filter(sections, &(&1.type == :table))

      refute String.contains?(figure.content, "| Col | Value |")
      assert String.contains?(table.content, "| Col | Value |")
    end
  end

  # ---------------------------------------------------------------------------
  # parse_layout/2 — plain text format
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 plain text" do
    test "splits on double newlines into paragraphs" do
      text = "First paragraph.\n\nSecond paragraph.\n\nThird."
      sections = DocumentChunker.parse_layout(text, format: :text)

      assert length(sections) == 3
      assert Enum.all?(sections, &(&1.type == :paragraph))
    end

    test "filters out empty paragraphs" do
      text = "Content.\n\n\n\n\n\nMore content."
      sections = DocumentChunker.parse_layout(text, format: :text)
      assert length(sections) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # parse_layout/2 — real PDF-to-markdown patterns (python library output)
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 bold body text vs headings" do
    test "short bold ALL-CAPS line is treated as a heading" do
      md = "**PREVENTION AND PROTECTION AT DANGER POINTS**\n\nBody content follows."
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))
      assert length(headings) == 1
      assert hd(headings).title == "PREVENTION AND PROTECTION AT DANGER POINTS"
    end

    test "long bold sentence is NOT parsed as a heading" do
      md = """
      **The first part of paragraph 4.4.1 specifies that the parts of the control system related to safety must conform to EN ISO 13849-1 performance level c.**

      Normal paragraph content.
      """

      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))

      assert headings == [],
             "Long bold sentence should be body text, not a heading — got: #{inspect(Enum.map(headings, & &1.title))}"
    end

    test "multiple consecutive long bold lines are treated as paragraph content, not headings" do
      md = """
      **La première partie du paragraphe 4.4.1 spécifie que les parties du système de commande.**

      **relatives à la sécurité doivent être conformes à l'EN ISO 13849-1 niveau de performance c.**

      **Cela signifie que le niveau de performance c régit toutes les caractéristiques de sécurité.**
      """

      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))

      assert headings == [],
             "Long bold sentences must not create #{length(headings)} spurious headings"
    end
  end

  describe "parse_layout/2 bold heading candidate edge cases" do
    test "bold text ending with closing guillemet » is not a heading" do
      md = "**Conforme à la norme »**\n\nContent."
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))
      assert headings == []
    end

    test "bold text ending with closing double-quote is not a heading" do
      md = ~s(**La norme dit "conforme"**\n\nContent.)
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))
      assert headings == []
    end
  end

  describe "parse_layout/2 bold measurement labels" do
    test "bold dimension label **2.5 m** is not parsed as a heading" do
      md = "**2.5 m**\n\nSome description of the measurement."
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))

      assert headings == [],
             "**2.5 m** is a dimension, not a heading — got level #{inspect(Enum.map(headings, & &1.level))}"
    end

    test "bold dimension label **20 cm** is not parsed as a heading" do
      md = "**20 cm**\n\nSome description of the measurement."
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))

      assert headings == [],
             "**20 cm** is a dimension, not a heading"
    end

    test "bold numbered section title without dots is still a valid heading" do
      md = "**1 Sliding Door**\n\nContent about sliding doors."
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))
      assert length(headings) == 1
      assert hd(headings).level == 1
      assert hd(headings).title == "1 Sliding Door"
    end
  end

  describe "parse_layout/2 page comment stripping" do
    test "HTML page comment is ignored and produces no sections" do
      md = "<!-- page: 1 -->"
      sections = DocumentChunker.parse_layout(md)
      assert sections == []
    end

    test "page comment between content does not leak into surrounding sections" do
      md = """
      # Introduction

      First paragraph.

      <!-- page: 2 -->

      Second paragraph.
      """

      sections = DocumentChunker.parse_layout(md)

      contents = Enum.map_join(sections, " ", & &1.content)

      refute String.contains?(contents, "page:"),
             "page comment should be stripped from section content"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_layout/2 — HTML
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 html" do
    test "raises not-implemented error for HTML" do
      assert_raise RuntimeError, ~r/HTML parsing not implemented/, fn ->
        DocumentChunker.parse_layout("<h1>Hello</h1>", format: :html)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # chunk_sections/2 — basic chunking
  # ---------------------------------------------------------------------------

  describe "chunk_sections/2 nil content" do
    test "section with nil content is filtered out without error" do
      sections = [
        %Section{
          id: "s-nil",
          type: :heading,
          level: 1,
          title: "Nil Content",
          content: nil,
          parent_path: [],
          position: 0,
          tokens: 0
        },
        %Section{
          id: "s-real",
          type: :paragraph,
          level: nil,
          title: nil,
          content: "Actual content.",
          parent_path: [],
          position: 1,
          tokens: 2
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert length(chunks) == 1
      assert String.contains?(hd(chunks).content, "Actual content.")
    end
  end

  describe "chunk_sections/2" do
    test "produces chunks from sections" do
      sections = [
        %Section{
          id: "s1",
          type: :heading,
          level: 1,
          title: "Intro",
          content: "This is introductory content with enough words to matter.",
          parent_path: [],
          position: 0,
          tokens: 10
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert [_first | _] = chunks
      assert %Chunk{} = hd(chunks)
    end

    test "filters out sections with empty content" do
      sections = [
        %Section{
          id: "s1",
          type: :heading,
          level: 1,
          title: "Empty",
          content: "",
          parent_path: [],
          position: 0,
          tokens: 0
        },
        %Section{
          id: "s2",
          type: :heading,
          level: 1,
          title: "Has Content",
          content: "Some real content here.",
          parent_path: [],
          position: 1,
          tokens: 5
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert length(chunks) == 1
      assert String.contains?(hd(chunks).content, "Has Content")
    end

    test "splits large sections into multiple chunks" do
      # Build content that exceeds chunk_max_tokens (default 900)
      big_content =
        1..200
        |> Enum.map_join("\n\n", fn i ->
          "Sentence number #{i} with several words to inflate the count."
        end)

      sections = [
        %Section{
          id: "s1",
          type: :heading,
          level: 1,
          title: "Big Section",
          content: big_content,
          parent_path: [],
          position: 0,
          tokens: TokenEstimator.estimate(big_content)
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert length(chunks) > 1
    end

    test "splits paragraphs when a combined chunk exceeds max tokens" do
      System.set_config("embedding.chunk_min_tokens", 1)
      System.set_config("embedding.chunk_max_tokens", 7)

      sections = [
        %Section{
          id: "s-combine",
          type: :paragraph,
          level: nil,
          title: nil,
          content: "one two three four\n\nfive six seven eight",
          parent_path: [],
          position: 0,
          tokens: 20
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert length(chunks) == 2
    end

    test "splits oversized single paragraph into sentence chunks" do
      System.set_config("embedding.chunk_min_tokens", 1)
      System.set_config("embedding.chunk_max_tokens", 3)

      sections = [
        %Section{
          id: "s-sentence",
          type: :paragraph,
          level: nil,
          title: nil,
          content: "alpha beta gamma delta. epsilon zeta eta theta.",
          parent_path: [],
          position: 0,
          tokens: 50
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert length(chunks) >= 2
      assert Enum.any?(chunks, &String.contains?(&1.content, "alpha beta gamma delta"))
    end

    test "keeps overlong sentence as its own chunk when sentence exceeds max" do
      System.set_config("embedding.chunk_min_tokens", 1)
      System.set_config("embedding.chunk_max_tokens", 1)

      sections = [
        %Section{
          id: "s-long-sentence",
          type: :paragraph,
          level: nil,
          title: nil,
          content: "alpha beta gamma.",
          parent_path: [],
          position: 0,
          tokens: 10
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert chunk.content == "alpha beta gamma."
    end

    test "chunk includes section_path from heading" do
      sections = [
        %Section{
          id: "s1",
          type: :heading,
          level: 1,
          title: "Chapter 1",
          content: "Chapter content.",
          parent_path: [],
          position: 0,
          tokens: 3
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert chunk.section_path == ["Chapter 1"]
    end

    test "chunk metadata includes section_type and position" do
      sections = [
        %Section{
          id: "s1",
          type: :table,
          level: nil,
          title: nil,
          content: "| A | B |\n|---|---|\n| 1 | 2 |",
          parent_path: ["Heading"],
          position: 5,
          tokens: 10
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert chunk.metadata.section_type == :table
      assert chunk.metadata.position == 5
    end

    test "figure without parent path keeps raw content" do
      sections = [
        %Section{
          id: "s-figure",
          type: :figure,
          level: nil,
          title: "Fig",
          content: "![Fig](fig.png)",
          parent_path: [],
          position: 2,
          tokens: 3
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert chunk.content == "![Fig](fig.png)"
    end

    test "heading with nil title keeps parent-only section_path and raw content" do
      sections = [
        %Section{
          id: "s-heading-nil",
          type: :heading,
          level: 2,
          title: nil,
          content: "Body without heading prefix.",
          parent_path: ["Parent Only"],
          position: 4,
          tokens: 6
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert chunk.section_path == ["Parent Only"]
      assert chunk.content == "Body without heading prefix."
    end
  end

  # ---------------------------------------------------------------------------
  # chunk_sections/2 — title prepending
  # ---------------------------------------------------------------------------

  describe "chunk title prepending" do
    test "prepends heading prefix to heading chunks" do
      sections = [
        %Section{
          id: "s1",
          type: :heading,
          level: 2,
          title: "My Section",
          content: "Body text.",
          parent_path: [],
          position: 0,
          tokens: 3
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert String.starts_with?(chunk.content, "## My Section\n\n")
    end

    test "prepends parent title to table chunks" do
      sections = [
        %Section{
          id: "s1",
          type: :table,
          level: nil,
          title: nil,
          content: "| A | B |\n|---|---|\n| 1 | 2 |",
          parent_path: ["Chapter", "Details"],
          position: 3,
          tokens: 10
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert String.starts_with?(chunk.content, "## Details\n\n")
    end

    test "prepends parent title to figure chunks" do
      sections = [
        %Section{
          id: "s-figure-parent",
          type: :figure,
          level: nil,
          title: "Revenue Figure",
          content: "![Revenue](revenue.png)",
          parent_path: ["Report", "Quarterly"],
          position: 8,
          tokens: 5
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert String.starts_with?(chunk.content, "## Quarterly\n\n")
      assert chunk.section_path == ["Report", "Quarterly", "Revenue Figure"]
    end

    test "no prefix for paragraph without parent" do
      sections = [
        %Section{
          id: "s1",
          type: :paragraph,
          level: nil,
          title: nil,
          content: "Just a paragraph.",
          parent_path: [],
          position: 0,
          tokens: 4
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert chunk.content == "Just a paragraph."
    end
  end

  # ---------------------------------------------------------------------------
  # chunk_sections/2 — token compliance
  # ---------------------------------------------------------------------------

  describe "chunk token compliance" do
    test "no chunk exceeds chunk_max_tokens after splitting" do
      System.set_config("embedding.chunk_max_tokens", 10)
      System.set_config("embedding.chunk_min_tokens", 1)

      content = Enum.map_join(1..50, "\n\n", fn i -> "Word number #{i} with extra text here." end)

      sections = [
        %Section{
          id: "s-compliance",
          type: :paragraph,
          level: nil,
          title: nil,
          content: content,
          parent_path: [],
          position: 0,
          tokens: TokenEstimator.estimate(content)
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert length(chunks) > 1

      Enum.each(chunks, fn chunk ->
        assert chunk.tokens <= 10,
               "Chunk exceeded max_tokens (#{chunk.tokens} > 10): #{inspect(chunk.content)}"
      end)
    end

    test "heading chunk with prepended title does not exceed chunk_max_tokens" do
      # Title overhead must be factored in when splitting content, so that
      # prepending the heading prefix doesn't push chunks over the limit.
      System.set_config("embedding.chunk_max_tokens", 20)
      System.set_config("embedding.chunk_min_tokens", 1)

      # Multiple paragraphs so the splitter can distribute them across chunks
      content =
        Enum.map_join(1..15, "\n\n", fn i -> "Paragraph #{i} with some content words." end)

      sections = [
        %Section{
          id: "s-heading-compliance",
          type: :heading,
          level: 2,
          title: "My Section",
          content: content,
          parent_path: [],
          position: 0,
          tokens: TokenEstimator.estimate(content)
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert length(chunks) > 1

      Enum.each(chunks, fn chunk ->
        assert chunk.tokens <= 20,
               "Heading chunk exceeded max_tokens (#{chunk.tokens} > 20): #{inspect(chunk.content)}"
      end)
    end

    test "heading with long title splits into at least 3 chunks all within max_tokens" do
      # Title overhead is significant — effective content budget per chunk is reduced.
      # With max=15 and a ~4-token title overhead, each content chunk can hold ~11 tokens.
      # 30 paragraphs of ~5 tokens each = ~150 content tokens → expect well over 3 chunks.
      System.set_config("embedding.chunk_max_tokens", 15)
      System.set_config("embedding.chunk_min_tokens", 1)

      content =
        Enum.map_join(1..30, "\n\n", fn i -> "Item #{i} with text." end)

      sections = [
        %Section{
          id: "s-long-title",
          type: :heading,
          level: 2,
          title: "Long Descriptive Section Title",
          content: content,
          parent_path: [],
          position: 0,
          tokens: TokenEstimator.estimate(content)
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)

      assert length(chunks) >= 3,
             "Expected at least 3 chunks, got #{length(chunks)}"

      Enum.each(chunks, fn chunk ->
        assert chunk.tokens <= 15,
               "Chunk exceeded max_tokens (#{chunk.tokens} > 15): #{inspect(chunk.content)}"
      end)
    end

    test "table chunk with prepended parent title does not exceed chunk_max_tokens" do
      System.set_config("embedding.chunk_max_tokens", 20)
      System.set_config("embedding.chunk_min_tokens", 1)

      content =
        Enum.map_join(1..15, "\n\n", fn i -> "| Row #{i} | Value #{i} |" end)

      sections = [
        %Section{
          id: "s-table-compliance",
          type: :table,
          level: nil,
          title: nil,
          content: content,
          parent_path: ["Chapter", "Long Parent Section Title"],
          position: 0,
          tokens: TokenEstimator.estimate(content)
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert length(chunks) > 1

      Enum.each(chunks, fn chunk ->
        assert chunk.tokens <= 20,
               "Table chunk exceeded max_tokens (#{chunk.tokens} > 20): #{inspect(chunk.content)}"
      end)
    end

    test "all chunks have positive token count" do
      sections = [
        %Section{
          id: "s1",
          type: :heading,
          level: 1,
          title: "Section",
          content: "Some content with several words.",
          parent_path: [],
          position: 0,
          tokens: 6
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert Enum.all?(chunks, fn chunk -> chunk.tokens > 0 end)
    end
  end

  # ---------------------------------------------------------------------------
  # parse_layout/2 — paragraph before first heading
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 paragraph before first heading" do
    test "content before first heading becomes a :paragraph section" do
      md = "Preamble text before any heading.\n\n# First Heading\n\nHeading body."
      sections = DocumentChunker.parse_layout(md)

      paragraphs = Enum.filter(sections, &(&1.type == :paragraph))
      assert paragraphs != []
      assert Enum.any?(paragraphs, &String.contains?(&1.content, "Preamble text"))
    end

    test "preamble paragraph has empty parent_path" do
      md = "Intro paragraph.\n\n# Heading\n\nContent."
      sections = DocumentChunker.parse_layout(md)

      [para] = Enum.filter(sections, &(&1.type == :paragraph))
      assert para.parent_path == []
    end
  end

  # ---------------------------------------------------------------------------
  # parse_layout/2 — heading level capping
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 heading level capping" do
    test "deeply nested italic heading is capped at level 6" do
      # 6 dots => level would be 7 without the cap
      md = "_1.2.3.4.5.6.7_ _Deep Section_\n\nContent."
      sections = DocumentChunker.parse_layout(md)

      heading = Enum.find(sections, &(&1.type == :heading))
      assert heading != nil
      assert heading.level == 6
    end

    test "standard markdown heading level 6 is not capped" do
      md = "###### Level Six\n\nContent."
      sections = DocumentChunker.parse_layout(md)

      [heading] = Enum.filter(sections, &(&1.type == :heading))
      assert heading.level == 6
    end
  end

  # ---------------------------------------------------------------------------
  # parse_layout/2 — table parent_path via heading stack
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 table parent_path via heading stack" do
    test "table after a heading inherits heading title in parent_path" do
      md = """
      # Chapter One

      ## Data Section

      | Name | Value |
      |------|-------|
      | X    | 1     |
      """

      sections = DocumentChunker.parse_layout(md)
      [table] = Enum.filter(sections, &(&1.type == :table))

      assert "Data Section" in table.parent_path
    end

    test "table at document root between headings has non-empty parent_path" do
      md = """
      # Top Level

      | A | B |
      |---|---|
      | 1 | 2 |

      ## Sub Heading
      """

      sections = DocumentChunker.parse_layout(md)
      [table] = Enum.filter(sections, &(&1.type == :table))

      assert table.parent_path == ["Top Level"]
    end
  end

  # ---------------------------------------------------------------------------
  # chunk_sections/2 — chunk ID format
  # ---------------------------------------------------------------------------

  describe "chunk ID format" do
    test "chunk IDs follow chunk_N_M pattern" do
      sections = [
        %Section{
          id: "s1",
          type: :paragraph,
          level: nil,
          title: nil,
          content: "First paragraph.",
          parent_path: [],
          position: 0,
          tokens: 3
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert String.starts_with?(chunk.id, "chunk_")
      assert Regex.match?(~r/^chunk_\d+_\d+$/, chunk.id)
    end

    test "multiple sections produce distinct chunk IDs" do
      sections =
        Enum.map(1..3, fn i ->
          %Section{
            id: "s#{i}",
            type: :paragraph,
            level: nil,
            title: nil,
            content: "Content for section #{i}.",
            parent_path: [],
            position: i,
            tokens: 4
          }
        end)

      chunks = DocumentChunker.chunk_sections(sections)
      ids = Enum.map(chunks, & &1.id)
      assert ids == Enum.uniq(ids)
    end
  end

  # ---------------------------------------------------------------------------
  # chunk_sections/2 — combine_paragraphs final accumulation
  # ---------------------------------------------------------------------------

  describe "chunk_sections/2 combine_paragraphs final accumulation" do
    test "last group of paragraphs is included even when below min_tokens" do
      System.set_config("embedding.chunk_min_tokens", 100)
      System.set_config("embedding.chunk_max_tokens", 200)

      # Short content that won't reach min_tokens but must still appear in output
      sections = [
        %Section{
          id: "s-final",
          type: :paragraph,
          level: nil,
          title: nil,
          content: "Short final paragraph.\n\nAnother short paragraph.",
          parent_path: [],
          position: 0,
          tokens: TokenEstimator.estimate("Short final paragraph.\n\nAnother short paragraph.")
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)
      assert chunks != []
      assert Enum.any?(chunks, &String.contains?(&1.content, "Short final paragraph"))
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end: parse_layout |> chunk_sections
  # ---------------------------------------------------------------------------

  describe "end-to-end pipeline" do
    test "markdown document produces valid chunks" do
      md = """
      # Introduction

      This is the introduction to the document. It contains enough text
      to form at least one chunk when processed through the pipeline.

      ## Background

      Some background information that provides context for the reader.

      ## Data

      | Metric | Value |
      |--------|-------|
      | Users  | 1000  |
      | Revenue| 50000 |

      ### Analysis

      The analysis section digs deeper into the data presented above.
      """

      sections = DocumentChunker.parse_layout(md)
      assert sections != []

      chunks = DocumentChunker.chunk_sections(sections)
      assert chunks != []
      assert Enum.all?(chunks, &is_binary(&1.content))
      assert Enum.all?(chunks, &is_list(&1.section_path))
      assert Enum.all?(chunks, &is_integer(&1.tokens))
    end
  end
end
