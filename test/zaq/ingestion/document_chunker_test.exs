defmodule Zaq.Ingestion.DocumentChunkerTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.TokenEstimator
  alias Zaq.Ingestion.DocumentChunker
  alias Zaq.Ingestion.DocumentChunker.{Chunk, Section}

  # ---------------------------------------------------------------------------
  # parse_layout/2 — basics
  # ---------------------------------------------------------------------------

  describe "parse_layout/2 basics" do
    test "returns empty list for blank input" do
      assert DocumentChunker.parse_layout("") == []
      assert DocumentChunker.parse_layout("   ") == []
      assert DocumentChunker.parse_layout("\n\n") == []
    end

    test "raises on unsupported format" do
      assert_raise ArgumentError, ~r/Invalid format/, fn ->
        DocumentChunker.parse_layout("hello", format: :pdf)
      end
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

  describe "chunk_sections/2" do
    setup do
      original = Application.get_env(:zaq, Zaq.Ingestion)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:zaq, Zaq.Ingestion)
        else
          Application.put_env(:zaq, Zaq.Ingestion, original)
        end
      end)

      :ok
    end

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
      Application.put_env(:zaq, Zaq.Ingestion, chunk_min_tokens: 1, chunk_max_tokens: 7)

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
      Application.put_env(:zaq, Zaq.Ingestion, chunk_min_tokens: 1, chunk_max_tokens: 3)

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
      Application.put_env(:zaq, Zaq.Ingestion, chunk_min_tokens: 1, chunk_max_tokens: 1)

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
