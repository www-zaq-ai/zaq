defmodule Zaq.Ingestion.DocumentChunkerTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.TokenEstimator
  alias Zaq.Ingestion.DocumentChunker
  alias Zaq.Ingestion.DocumentChunker.{Chunk, Section}
  alias Zaq.System

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

      # Verbatim contract: the stored content is exactly the section body —
      # the title reaches the embedder via embedding_input, never content.
      # (Parse-level heading sections are never empty anymore: parsing seeds
      # them with their own raw heading line.)
      assert hd(chunks).content == "Some real content here."
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

    test "starts a new sentence chunk when the next sentence would exceed max tokens" do
      System.set_config("embedding.chunk_min_tokens", 1)
      System.set_config("embedding.chunk_max_tokens", 4)

      sections = [
        %Section{
          id: "s-sentence-boundary",
          type: :paragraph,
          level: nil,
          title: nil,
          content: "one two. three four five six.",
          parent_path: [],
          position: 0,
          tokens: 20
        }
      ]

      chunks = DocumentChunker.chunk_sections(sections)

      assert Enum.map(chunks, & &1.content) == ["one two.", "three four five six."]
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
  # chunk_sections/2 — store-raw / embed-enriched split
  #
  # `content` is always the verbatim section body; the section-path context
  # lives only in the transient `embedding_input` (embed-only, never
  # persisted).
  # ---------------------------------------------------------------------------

  describe "store-raw / embed-enriched split" do
    test "heading chunks: verbatim content, section-path-prefixed embedding_input" do
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
      assert chunk.content == "Body text."
      assert chunk.embedding_input == "My Section\n\nBody text."
    end

    test "table chunks: verbatim content, parent-trail-prefixed embedding_input" do
      table = "| A | B |\n|---|---|\n| 1 | 2 |"

      sections = [
        %Section{
          id: "s1",
          type: :table,
          level: nil,
          title: nil,
          content: table,
          parent_path: ["Chapter", "Details"],
          position: 3,
          tokens: 10
        }
      ]

      [chunk] = DocumentChunker.chunk_sections(sections)
      assert chunk.content == table
      assert chunk.embedding_input == "Chapter > Details\n\n" <> table
    end

    test "figure chunks: verbatim content, full-path embedding_input" do
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
      assert chunk.content == "![Revenue](revenue.png)"
      assert chunk.section_path == ["Report", "Quarterly", "Revenue Figure"]

      assert chunk.embedding_input ==
               "Report > Quarterly > Revenue Figure\n\n![Revenue](revenue.png)"
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
      assert chunk.embedding_input == "Just a paragraph."
    end

    test "context prefix is omitted when it alone would consume the token budget" do
      # chunk_max_tokens default is 900 (~692 words at the 1.3 ratio); a
      # pathological section path longer than the budget must not push
      # embedding_input past the limit — the prefix is dropped instead.
      huge_title = Enum.map_join(1..800, " ", fn i -> "segment#{i}" end)

      assert Chunk.embedding_input("Body text.", [huge_title]) == "Body text."
      assert Chunk.context_prefix([huge_title]) == ""

      # sanity: a normal path keeps the prefix
      assert Chunk.embedding_input("Body text.", ["A", "B"]) == "A > B\n\nBody text."
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

  # ---------------------------------------------------------------------------
  # chunk_sections/2 — unterminated final line (text.txt regression)
  #
  # Reproduces a document where the last line ("Load balancer IP:
  # `10.0.0.42`") has NO trailing newline. Verifies that content on an
  # unterminated final line survives parse_layout/2 + chunk_sections/2 and is
  # not silently dropped.
  # ---------------------------------------------------------------------------

  describe "chunk_sections/2 unterminated final line" do
    @lb_lines [
      "### Sample Cluster",
      "This section contains placeholder notes used only to exercise the chunker.",
      "",
      "Name: example-cluster",
      "#### Storage",
      "- example-storage - type retain",
      "",
      "#### Workloads",
      "- example-app",
      "- example-deployment",
      "- example-worker, example-backend",
      "",
      "#### Services",
      "- example-app",
      "- example-deployment",
      "- example-queue",
      "",
      "#### Ingress",
      "",
      "Ingress is handled by the example controller.",
      "Load balancer IP: `10.0.0.42`"
    ]

    test "preserves the final load-balancer line when the document has no trailing newline" do
      # Exact reproduction of text.txt: the last line is unterminated (no \n).
      text = Enum.join(@lb_lines, "\n")
      refute String.ends_with?(text, "\n")

      sections = DocumentChunker.parse_layout(text)
      chunks = DocumentChunker.chunk_sections(sections)
      combined = Enum.map_join(chunks, "\n", & &1.content)

      assert String.contains?(combined, "Load balancer"),
             "expected the load balancer line to survive chunking, got:\n#{combined}"

      assert String.contains?(combined, "10.0.0.42"),
             "expected the load balancer IP to survive chunking, got:\n#{combined}"
    end

    test "trailing-newline variant also preserves the final line (control)" do
      text = Enum.join(@lb_lines, "\n") <> "\n"

      sections = DocumentChunker.parse_layout(text)
      chunks = DocumentChunker.chunk_sections(sections)
      combined = Enum.map_join(chunks, "\n", & &1.content)

      assert String.contains?(combined, "Load balancer")
      assert String.contains?(combined, "10.0.0.42")
    end
  end
end
