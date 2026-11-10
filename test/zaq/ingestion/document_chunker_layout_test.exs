defmodule Zaq.Ingestion.DocumentChunkerLayoutTest do
  use ExUnit.Case, async: true

  alias Zaq.Ingestion.DocumentChunker
  alias Zaq.Ingestion.DocumentChunker.Section

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

    # Golden rule: `#`…`######` are the ONLY heading markup. Bold/italic
    # lines are body text — the chunker never invents structure from them.

    test "does not promote bold numbered lines to headings" do
      md = "**1.** **Introduction**\n\nSome intro text."
      sections = DocumentChunker.parse_layout(md)

      assert Enum.filter(sections, &(&1.type == :heading)) == []
      assert Enum.any?(sections, &String.contains?(&1.content, "**1.** **Introduction**"))
    end

    test "does not promote italic numbered lines to headings" do
      md = "_1.1_ _Details_\n\nSome details."
      sections = DocumentChunker.parse_layout(md)

      assert Enum.filter(sections, &(&1.type == :heading)) == []
      assert Enum.any?(sections, &String.contains?(&1.content, "_1.1_ _Details_"))
    end

    test "does not promote simple bold lines to headings" do
      md = "**Overview**\n\nSome details."
      sections = DocumentChunker.parse_layout(md)

      assert Enum.filter(sections, &(&1.type == :heading)) == []
      assert Enum.any?(sections, &String.contains?(&1.content, "**Overview**"))
    end

    test "does not promote simple italic lines to headings" do
      md = "_Overview_\n\nSome details."
      sections = DocumentChunker.parse_layout(md)

      assert Enum.filter(sections, &(&1.type == :heading)) == []
      assert Enum.any?(sections, &String.contains?(&1.content, "_Overview_"))
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

    test "does not promote bold multi-level numbered lines to headings" do
      md = "**1.2** **Details**\n\nSection content."
      sections = DocumentChunker.parse_layout(md)

      assert Enum.filter(sections, &(&1.type == :heading)) == []
      assert Enum.any?(sections, &String.contains?(&1.content, "**1.2** **Details**"))
    end

    test "skips italic numbered TOC entry ending with page number" do
      md = "_1.2_ _Introduction_ _3_\n\nRegular paragraph."
      sections = DocumentChunker.parse_layout(md)

      headings = Enum.filter(sections, &(&1.type == :heading))
      assert headings == []
    end

    test "does not promote italic multi-level numbered lines to headings" do
      md = "_1.2.3_ _Deep Details_\n\nBody content."
      sections = DocumentChunker.parse_layout(md)

      assert Enum.filter(sections, &(&1.type == :heading)) == []
      assert Enum.any?(sections, &String.contains?(&1.content, "_1.2.3_ _Deep Details_"))
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

    test "pipe line at document root remains paragraph content when no table is active" do
      md = "| not a table"
      sections = DocumentChunker.parse_layout(md)

      assert [%Section{type: :paragraph, content: "| not a table"}] = sections
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

    test "terminates table when non-table content follows immediately" do
      md = """
      | Name | Value |
      |------|-------|
      | A    | 1     |
      Immediate paragraph after table.
      """

      sections = DocumentChunker.parse_layout(md)
      [table] = Enum.filter(sections, &(&1.type == :table))
      [paragraph] = Enum.filter(sections, &(&1.type == :paragraph))

      refute String.contains?(table.content, "Immediate paragraph")
      assert paragraph.content == "Immediate paragraph after table."
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

    test "non-image bang link stays in surrounding content" do
      md = "# Doc\n\n![not closed"
      sections = DocumentChunker.parse_layout(md)

      assert Enum.any?(sections, &(&1.type == :heading && &1.content =~ "![not closed"))
      assert Enum.filter(sections, &(&1.type == :figure)) == []
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

    test "vision image with blank filename keeps blank title" do
      md = """
      > **[Image: ]**
      > Description with missing source filename.
      """

      [figure] =
        md
        |> DocumentChunker.parse_layout()
        |> Enum.filter(&(&1.type == :figure))

      assert figure.title == ""
      assert String.contains?(figure.content, "Description with missing source filename.")
    end

    test "vision image at end of document keeps all description lines" do
      md = "> **[Image: final.png]**\n> First description line.\n> Second description line."

      [figure] =
        md
        |> DocumentChunker.parse_layout()
        |> Enum.filter(&(&1.type == :figure))

      assert figure.title == "final.png"
      assert String.contains?(figure.content, "First description line.")
      assert String.contains?(figure.content, "Second description line.")
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
    test "short bold ALL-CAPS line stays body text (golden rule: no invented headings)" do
      md = "**PREVENTION AND PROTECTION AT DANGER POINTS**\n\nBody content follows."
      sections = DocumentChunker.parse_layout(md)

      assert Enum.filter(sections, &(&1.type == :heading)) == []

      assert Enum.any?(
               sections,
               &String.contains?(&1.content, "**PREVENTION AND PROTECTION AT DANGER POINTS**")
             )
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

    test "bold numbered section title stays body text (golden rule: no invented headings)" do
      md = "**1 Sliding Door**\n\nContent about sliding doors."
      sections = DocumentChunker.parse_layout(md)

      assert Enum.filter(sections, &(&1.type == :heading)) == []
      assert Enum.any?(sections, &String.contains?(&1.content, "**1 Sliding Door**"))
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
    test "deeply nested italic numbering stays body text (golden rule: no invented headings)" do
      md = "_1.2.3.4.5.6.7_ _Deep Section_\n\nContent."
      sections = DocumentChunker.parse_layout(md)

      assert Enum.filter(sections, &(&1.type == :heading)) == []
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
end
