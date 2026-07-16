defmodule Zaq.Ingestion.ChunkVerbatimIngestionTest do
  @moduledoc """
  Full-pipeline validation of the verbatim-chunking plan
  (`docs/exec-plans/active/2026-07-16-chunk-verbatim-content-interim-fix.md`)
  against `test/fixtures/chunk_verbatim_ingestion.md`.

  Runs the REAL ingestion path — `process_single_file_with_report/1`: file
  read, document upsert, layout parsing, chunking, embedding, chunk insert —
  and the REAL hybrid retrieval path (`bm25_search_group_by/2` +
  `query_extraction/2`). The only stub is the external embedding HTTP
  boundary (`Req.Test`); no internal hop is stubbed.

  §1  Chunk count
  §2  Chunk metadata + heading paths + document order
  §3  Verbatim invariant — no chunk content is manipulated or removed
  §4  Retrieval — every stored chunk is findable
  §5  Step 1b gates — embed-enriched input at the HTTP boundary, no-headings
      documents get no prefix, worker derives embedding_input from payload

  EXPECTED TO FAIL against the current `DocumentChunker` (plan Step 1 red
  gate): today the fixture yields 4 chunks (not 6), the empty
  "Emergency Shutdown Criteria" heading is dropped, oversized-paragraph
  split chunks are whitespace-rewritten (not substrings of the source), and
  the two split chunks are stored in reverse reading order.

  Requires PostgreSQL (native FTS). Run with:

      mix test --include integration test/zaq/ingestion/chunk_verbatim_ingestion_test.exs

  Note: the embedding stub returns an identical vector for every input, so
  the vector leg ties on all chunks and cannot discriminate. Retrieval
  assertions therefore check the BM25 leg explicitly, then confirm the
  verbatim content flows through `query_extraction/2` end-to-end.
  """

  use Zaq.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox

  alias Zaq.Ingestion.{
    Chunk,
    DocumentProcessor,
    FTSBackend,
    IngestChunkJob,
    IngestChunkWorker,
    IngestJob
  }

  alias Zaq.SystemConfigFixtures

  # @moduletag :integration
  @moduletag capture_log: true

  @embedding_dim 1536

  @fixture_path Path.expand("../../fixtures/chunk_verbatim_ingestion.md", __DIR__)
  @no_headings_fixture_path Path.expand(
                              "../../fixtures/chunk_verbatim_no_headings.md",
                              __DIR__
                            )

  @intro_path ["Solar Array Maintenance Handbook"]
  @quarterly_path ["Solar Array Maintenance Handbook", "Quarterly Inspection Procedure"]
  @emergency_path ["Solar Array Maintenance Handbook", "Emergency Shutdown Criteria"]
  @warranty_path ["Vendor Warranty Contacts"]

  @heading_lines [
    "# Solar Array Maintenance Handbook",
    "## Quarterly Inspection Procedure",
    "## Emergency Shutdown Criteria",
    "# Vendor Warranty Contacts"
  ]

  # ---------------------------------------------------------------------------
  # Setup — mirrors BM25FusionValidationTest: native FTS, real chunks table,
  # stubbed embedding HTTP boundary. The chunk token budget is the default
  # 400/900 from the embedding config; the fixture's intro paragraph is sized
  # (923 words ≈ 1200 estimated tokens) to exceed one chunk but fit in two.
  # ---------------------------------------------------------------------------

  setup_all do
    Sandbox.mode(Zaq.Repo, :auto)
    FTSBackend.reset_cache()
    :persistent_term.put({FTSBackend, :backend}, FTSBackend.Native)

    try do
      Chunk.create_table(@embedding_dim)
    after
      FTSBackend.reset_cache()
      Sandbox.mode(Zaq.Repo, :manual)
    end

    :ok
  end

  setup do
    FTSBackend.reset_cache()
    :persistent_term.put({FTSBackend, :backend}, FTSBackend.Native)

    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})

    original_env = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, use_bm25: true)

    on_exit(fn ->
      FTSBackend.reset_cache()

      if is_nil(original_env),
        do: Application.delete_env(:zaq, Zaq.Ingestion),
        else: Application.put_env(:zaq, Zaq.Ingestion, original_env)
    end)

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      body = Jason.encode!(%{"data" => [%{"embedding" => List.duplicate(0.1, @embedding_dim)}]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    :ok
  end

  defp ingest_fixture! do
    assert {:ok, document, report} =
             DocumentProcessor.process_single_file_with_report(@fixture_path)

    assert report.failed_chunks == 0,
           "full ingestion must store every chunk; report: #{inspect(report)}"

    chunks =
      Chunk
      |> where([c], c.document_id == ^document.id)
      |> order_by([c], asc: c.chunk_index)
      |> Repo.all()

    {document, chunks}
  end

  defp chunks_for(chunks, section_path),
    do: Enum.filter(chunks, &(&1.section_path == section_path))

  # Builds a BM25 query by quoting the chunk's own leading words. AND
  # semantics (websearch_to_tsquery) guarantee every term is present in the
  # chunk by construction, so retrieval must be able to find it.
  defp query_from(content) do
    content
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.take(8)
    |> Enum.join(" ")
  end

  defp bm25_section_paths(query, doc_id) do
    assert {:ok, grouped} = DocumentProcessor.bm25_search_group_by(query, 20)
    grouped |> Map.get(doc_id, %{}) |> Map.keys()
  end

  # Replaces the setup stub with one that also reports every embedding
  # request body back to the test process, so §5 can assert WHAT was
  # embedded (the identical-vector stub makes §1-§4 blind to that).
  defp stub_embedding_capture(parent) do
    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      send(parent, {:embed_input, embed_input_from(conn)})

      body = Jason.encode!(%{"data" => [%{"embedding" => List.duplicate(0.1, @embedding_dim)}]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp embed_input_from(conn) do
    case conn.body_params do
      %{"input" => input} ->
        input

      _ ->
        {:ok, raw, _conn} = Plug.Conn.read_body(conn)
        raw |> Jason.decode!() |> Map.fetch!("input")
    end
  end

  defp captured_embed_inputs(acc \\ []) do
    receive do
      {:embed_input, input} -> captured_embed_inputs([input | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The plan's enrichment contract: context prefix is the joined section
  # path; an empty path means no prefix at all (not a bare "\n\n").
  defp expected_embedding_input(%{section_path: [], content: content}), do: content

  defp expected_embedding_input(%{section_path: path, content: content}),
    do: Enum.join(path, " > ") <> "\n\n" <> content

  # ---------------------------------------------------------------------------
  # §1 — Chunk count
  #
  # Expected post-fix breakdown (min/max token budget 400/900):
  #   Intro H1 section  → 3 chunks: the seeded heading line flushes alone
  #     (7 tokens, next paragraph would blow the budget), then the 923-word
  #     paragraph (~1200 tokens > ~894 effective max) sentence-splits into 2.
  #   Quarterly H2      → 1 chunk (heading + paragraph + list, well under max)
  #   Emergency H2      → 1 chunk (heading-only section — retained, not dropped)
  #   Warranty H1       → 1 chunk (heading + paragraph)
  # Today's chunker produces 4 (intro 2, quarterly 1, warranty 1, emergency
  # dropped) — this test is the plan's red gate.
  # ---------------------------------------------------------------------------

  describe "§1 chunk count" do
    test "fixture yields exactly 6 chunks: 3 + 1 + 1 + 1 per section" do
      {_document, chunks} = ingest_fixture!()

      counts = Enum.frequencies_by(chunks, & &1.section_path)

      assert counts == %{
               @intro_path => 3,
               @quarterly_path => 1,
               @emergency_path => 1,
               @warranty_path => 1
             },
             "per-section chunk counts diverged: #{inspect(counts)}"

      assert length(chunks) == 6
    end
  end

  # ---------------------------------------------------------------------------
  # §2 — Metadata, heading paths, document order
  # ---------------------------------------------------------------------------

  describe "§2 chunk metadata and heading paths" do
    test "chunk_index is a contiguous 1..N sequence in document order" do
      {_document, chunks} = ingest_fixture!()

      assert Enum.map(chunks, & &1.chunk_index) == Enum.to_list(1..length(chunks))

      # Sections must appear in source order: intro, quarterly, emergency, warranty.
      assert Enum.map(chunks, & &1.section_path) |> Enum.dedup() == [
               @intro_path,
               @quarterly_path,
               @emergency_path,
               @warranty_path
             ]
    end

    test "split chunks of the oversized paragraph keep reading order" do
      {_document, chunks} = ingest_fixture!()

      # "logistics warehouse" is in the paragraph's opening sentences,
      # "diary" in its final sentence — the chunk holding the opening must
      # come first. Today's chunker stores the two split chunks reversed.
      warehouse_idx =
        Enum.find(chunks, &String.contains?(&1.content, "logistics warehouse")).chunk_index

      diary_idx = Enum.find(chunks, &String.contains?(&1.content, "diary")).chunk_index

      assert warehouse_idx < diary_idx,
             "split chunks out of reading order: warehouse=#{warehouse_idx}, diary=#{diary_idx}"
    end

    test "every chunk carries heading-section metadata matching its path" do
      {_document, chunks} = ingest_fixture!()

      expected_levels = %{
        @intro_path => 1,
        @quarterly_path => 2,
        @emergency_path => 2,
        @warranty_path => 1
      }

      for chunk <- chunks do
        assert chunk.metadata["section_type"] == "heading",
               "chunk #{chunk.chunk_index} section_type: #{inspect(chunk.metadata)}"

        assert chunk.metadata["section_level"] == expected_levels[chunk.section_path],
               "chunk #{chunk.chunk_index} level mismatch for #{inspect(chunk.section_path)}"

        assert is_integer(chunk.metadata["position"])
        assert is_integer(chunk.metadata["tokens"]) and chunk.metadata["tokens"] > 0
      end
    end
  end

  # ---------------------------------------------------------------------------
  # §3 — Verbatim invariant: nothing manipulated, nothing removed
  # ---------------------------------------------------------------------------

  describe "§3 verbatim content" do
    test "every chunk is a byte-exact substring of document.content" do
      {document, chunks} = ingest_fixture!()

      for chunk <- chunks do
        assert :binary.match(document.content, chunk.content) != :nomatch,
               """
               chunk #{chunk.chunk_index} (#{inspect(chunk.section_path)}) was \
               manipulated — its bytes do not exist in the source document:
               #{inspect(chunk.content, printable_limit: 300)}
               """
      end
    end

    test "no source heading line is removed — each appears verbatim in a chunk" do
      {_document, chunks} = ingest_fixture!()
      corpus = Enum.map_join(chunks, "\n\n", & &1.content)

      for heading <- @heading_lines do
        assert String.contains?(corpus, heading),
               "heading removed from corpus: #{heading}"
      end
    end

    test "list items survive verbatim inside their section chunk" do
      {_document, chunks} = ingest_fixture!()

      [quarterly] = chunks_for(chunks, @quarterly_path)

      assert String.contains?(
               quarterly.content,
               "- Verify torque on all busbar connections\n- Photograph any discoloured MC4 connector"
             ),
             "list items rewritten or reordered: #{inspect(quarterly.content)}"
    end
  end

  # ---------------------------------------------------------------------------
  # §4 — Retrieval: every stored chunk is findable
  # ---------------------------------------------------------------------------

  describe "§4 retrieval finds every chunk" do
    test "each chunk is retrievable by quoting its own leading words" do
      {document, chunks} = ingest_fixture!()

      for chunk <- chunks do
        query = query_from(chunk.content)

        assert chunk.section_path in bm25_section_paths(query, document.id),
               "BM25 cannot find chunk #{chunk.chunk_index} with its own words: #{inspect(query)}"

        assert {:ok, results} = DocumentProcessor.query_extraction(query, skip_permissions: true)

        assert Enum.any?(results, &(&1["content"] == chunk.content)),
               "query_extraction did not return chunk #{chunk.chunk_index} verbatim for #{inspect(query)}"
      end
    end

    test "the document title query surfaces the intro section" do
      {document, _chunks} = ingest_fixture!()

      assert @intro_path in bm25_section_paths("Solar Array Maintenance Handbook", document.id)
    end

    test "the heading-only Emergency Shutdown section is retrievable" do
      {document, chunks} = ingest_fixture!()

      assert [emergency] = chunks_for(chunks, @emergency_path),
             "Emergency Shutdown Criteria section missing from the corpus"

      assert @emergency_path in bm25_section_paths("emergency shutdown criteria", document.id)

      assert {:ok, results} =
               DocumentProcessor.query_extraction("emergency shutdown criteria",
                 skip_permissions: true
               )

      assert Enum.any?(results, &(&1["content"] == emergency.content))
    end
  end

  # ---------------------------------------------------------------------------
  # §5 — Step 1b gates: store-raw / embed-enriched split
  #
  # Captures the embedding request bodies at the HTTP boundary. Red until
  # plan Steps 3 + 5 land: today the boundary receives `chunk.content` with
  # the synthetic heading baked in, never a section-path-prefixed
  # `embedding_input`, and the worker has no derivation step.
  # ---------------------------------------------------------------------------

  describe "§5 embedding input (store-raw / embed-enriched)" do
    test "every chunk-embed request body is the section-path prefix + verbatim content" do
      stub_embedding_capture(self())

      {document, chunks} = ingest_fixture!()
      inputs = captured_embed_inputs()

      # one embed per chunk at minimum; other embeds may exist, but every
      # chunk's enriched input must be among them
      assert length(inputs) >= length(chunks)

      for chunk <- chunks do
        expected = expected_embedding_input(chunk)

        assert expected in inputs,
               """
               no embed request matched chunk #{chunk.chunk_index} \
               (#{inspect(chunk.section_path)}).
               expected embedding_input:
               #{inspect(expected, printable_limit: 300)}
               captured inputs:
               #{inspect(inputs, printable_limit: 600)}
               """

        # the enriched input must never leak into storage
        assert :binary.match(document.content, chunk.content) != :nomatch,
               "chunk #{chunk.chunk_index} stored non-verbatim content"
      end
    end

    test "a document with no headings embeds exactly its verbatim content — no prefix" do
      stub_embedding_capture(self())

      assert {:ok, document, report} =
               DocumentProcessor.process_single_file_with_report(@no_headings_fixture_path)

      assert report.failed_chunks == 0

      chunks =
        Chunk
        |> where([c], c.document_id == ^document.id)
        |> order_by([c], asc: c.chunk_index)
        |> Repo.all()

      inputs = captured_embed_inputs()

      assert chunks != [], "no-headings fixture produced no chunks"

      for chunk <- chunks do
        assert chunk.section_path == [],
               "headingless chunk got a section path: #{inspect(chunk.section_path)}"

        assert chunk.content in inputs,
               """
               empty section path must mean NO prefix (not a bare \"\\n\\n\"):
               expected the embed body to equal the chunk content verbatim.
               captured inputs: #{inspect(inputs, printable_limit: 600)}
               """

        assert :binary.match(document.content, chunk.content) != :nomatch
      end
    end

    test "the chunk worker derives embedding_input from the payload's section_path + content" do
      # Real document + chunks table from the fixture ingestion (setup's
      # non-capturing stub), then a handcrafted queued payload through the
      # REAL worker + REAL processor — only the embedding HTTP is stubbed.
      # config/test.exs points :document_processor at a Mox mock; this test
      # needs the real hop.
      original_processor = Application.get_env(:zaq, :document_processor)
      Application.put_env(:zaq, :document_processor, DocumentProcessor)

      on_exit(fn ->
        if is_nil(original_processor),
          do: Application.delete_env(:zaq, :document_processor),
          else: Application.put_env(:zaq, :document_processor, original_processor)
      end)

      {document, _chunks} = ingest_fixture!()

      content =
        "Torque values for the busbar clamps live in the vendor sheet.\n" <>
          "Do not paraphrase this line when embedding it."

      section_path = ["Solar Array Maintenance Handbook", "Quarterly Inspection Procedure"]

      ingest_job =
        %IngestJob{}
        |> IngestJob.changeset(%{
          file_path: @fixture_path,
          status: "processing",
          mode: "async",
          document_id: document.id
        })
        |> Repo.insert!()

      chunk_job =
        %IngestChunkJob{}
        |> IngestChunkJob.changeset(%{
          ingest_job_id: ingest_job.id,
          document_id: document.id,
          chunk_index: 99,
          chunk_payload: %{
            "id" => "step1b-derivation-gate",
            "content" => content,
            "section_path" => section_path,
            "tokens" => 24,
            "metadata" => %{}
          },
          status: "pending"
        })
        |> Repo.insert!()

      stub_embedding_capture(self())

      assert :ok =
               IngestChunkWorker.perform(%Oban.Job{
                 args: %{"chunk_job_id" => chunk_job.id, "job_id" => ingest_job.id},
                 attempt: 1,
                 max_attempts: 5
               })

      expected = Enum.join(section_path, " > ") <> "\n\n" <> content

      assert [^expected] = captured_embed_inputs()

      stored =
        Chunk
        |> where([c], c.document_id == ^document.id and c.chunk_index == 99)
        |> Repo.one!()

      assert stored.content == content,
             "worker path stored non-verbatim content: #{inspect(stored.content)}"
    end
  end
end
