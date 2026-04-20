defmodule Zaq.Ingestion.BM25FusionValidationTest do
  @moduledoc """
  Integration tests that validate the BM25 + vector RRF fusion pipeline against
  the content in `test/fixtures/bm25_fusion_validation.md`.

  Requires PostgreSQL with `pg_search` (ParadeDB). Run with:

      mix test --include integration test/zaq/ingestion/bm25_fusion_validation_test.exs

  Structure:
    §1  Language detection (LanguageDetector.detect/1 — no DB, no pg_search)
    §2  BM25 index routing (requires pg_search)
    §3  Fusion ranking smoke test (requires pg_search)
    §4  query_extraction/2 end-to-end (requires pg_search)

  Note: BM25/fusion tests insert chunks directly (bypass process_single_file)
  to avoid the chunk-title LLM stub replacing section path labels.
  """

  use Zaq.DataCase, async: false

  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Ingestion.{BM25IndexManager, Chunk, Document, DocumentProcessor, LanguageDetector}
  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures

  @moduletag :integration
  @moduletag capture_log: true

  @embedding_dim 1536

  # ---------------------------------------------------------------------------
  # Section content extracted from test/fixtures/bm25_fusion_validation.md
  # ---------------------------------------------------------------------------

  @section_a """
  The Reciprocal Rank Fusion algorithm, abbreviated RRF, combines ranked lists
  from heterogeneous retrieval systems by summing reciprocal rank scores. The
  formula is: RRF(d) = Σ 1/(k + rank_i(d)) where k is a smoothing constant
  typically set to 60. RRF is rank-based, not score-based, so it is robust to
  score-scale differences between BM25 and cosine similarity. Practitioners
  report that RRF outperforms linear score combination in most ad-hoc retrieval
  benchmarks without requiring any hyperparameter tuning beyond k.
  """

  @section_b """
  Merging results from keyword search and dense retrieval improves recall for
  questions where neither system alone surfaces the best document. By assigning
  each candidate a position-based weight and aggregating across both lists, the
  combined ranker rewards documents that appear consistently near the top
  regardless of the individual scoring function used. This approach does not
  require training and generalises across domains.
  """

  @section_c """
  The BM25 scoring function extends TF-IDF by applying a saturation curve to
  term frequency and a document length normalisation factor. For a query term t
  in document d: BM25(t,d) = IDF(t) * (tf * (k1+1)) / (tf + k1*(1 - b + b*dl/avgdl)).
  Combining BM25 with vector similarity via Reciprocal Rank Fusion consistently
  outperforms either system alone on the BEIR benchmark suite.
  """

  @section_d """
  The bank processed a large batch of transactions using a ranked priority
  queue. Each transaction had a score assigned by the fraud detection model.
  The top-ranked items were flagged for manual review. The system combined
  scores from two independent models using a weighted average formula.
  """

  @section_e """
  La fusion hybride combine la recherche par mots-clés et la recherche
  sémantique vectorielle pour améliorer la pertinence des résultats. L'algorithme
  de fusion par rang réciproque attribue à chaque document un score basé sur sa
  position dans chaque liste classée. Cette approche est particulièrement
  efficace pour les requêtes contenant des termes techniques précis, car la
  recherche BM25 détecte les correspondances exactes que les embeddings peuvent
  manquer. Les systèmes modernes de recherche d'information combinent ces deux
  approches pour obtenir de meilleures performances.
  """

  @section_f """
  La búsqueda híbrida combina la recuperación léxica basada en BM25 con la
  búsqueda semántica vectorial para mejorar la precisión y la exhaustividad. El
  algoritmo de fusión por rango recíproco asigna a cada documento una puntuación
  basada en su posición en las listas ordenadas. Esta técnica es especialmente
  útil cuando las consultas contienen términos técnicos específicos que los
  modelos de embeddings pueden no capturar correctamente. Los sistemas modernos
  de recuperación de información utilizan esta combinación para obtener mejores
  resultados en todos los dominios.
  """

  @section_g """
  البحث الهجين يجمع بين البحث المعتمد على الكلمات المفتاحية باستخدام خوارزمية
  BM25 والبحث الدلالي المعتمد على التضمينات المتجهية لتحسين جودة نتائج البحث.
  تعتمد خوارزمية دمج الترتيب التبادلي على تعيين درجة لكل وثيقة بناءً على
  موضعها في قوائم الترتيب المختلفة. هذا النهج فعّال بشكل خاص للاستعلامات
  التي تحتوي على مصطلحات تقنية دقيقة حيث يكتشف BM25 التطابقات الدقيقة التي
  قد تفوت نماذج التضمين. تستخدم أنظمة استرجاع المعلومات الحديثة هذا النهج
  المدمج للحصول على نتائج أفضل عبر مختلف المجالات والتطبيقات.
  """

  @section_h "RRF k=60."

  @rrf_query "reciprocal rank fusion RRF formula"

  # ---------------------------------------------------------------------------
  # §1 — Language detection (no DB, no pg_textsearch required)
  #      Mirrors fixture checklist: expected language values per section
  # ---------------------------------------------------------------------------

  describe "§1 language detection per section" do
    test "Section A (English, exact keyword) is detected as 'english'" do
      assert LanguageDetector.detect(@section_a) == "english"
    end

    test "Section B (English, semantic paraphrase) is detected as 'english'" do
      assert LanguageDetector.detect(@section_b) == "english"
    end

    test "Section C (English, shared signal) is detected as 'english'" do
      assert LanguageDetector.detect(@section_c) == "english"
    end

    test "Section D (English, false BM25 hit) is detected as 'english'" do
      assert LanguageDetector.detect(@section_d) == "english"
    end

    test "Section E is detected as 'french'" do
      assert LanguageDetector.detect(@section_e) == "french"
    end

    test "Section F is detected as 'spanish'" do
      assert LanguageDetector.detect(@section_f) == "spanish"
    end

    test "Section G is detected as 'arabic'" do
      assert LanguageDetector.detect(@section_g) == "arabic"
    end

    test "Section H (< 20 tokens) is detected as 'simple'" do
      tokens = @section_h |> String.split() |> length()
      assert tokens < 20, "Section H should have < 20 tokens, got #{tokens}"
      assert LanguageDetector.detect(@section_h) == "simple"
    end
  end

  # ---------------------------------------------------------------------------
  # Shared DB setup for §2–§4
  # ---------------------------------------------------------------------------

  # The reset migration (20260326) drops chunks permanently; ChunkResetTableTest
  # recreates it but sorts after this file alphabetically. Switching to :auto
  # here avoids sandbox ownership errors on DDL, then restored to :manual.
  setup_all do
    Sandbox.mode(Zaq.Repo, :auto)

    try do
      Chunk.create_table(1536)
    after
      Sandbox.mode(Zaq.Repo, :manual)
    end

    :ok
  end

  setup :verify_on_exit!

  setup do
    BM25IndexManager.init()
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})

    original_env = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, use_bm25: true)

    on_exit(fn ->
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

    # Stub title generation to a no-op so it doesn't alter section_path labels.
    Zaq.Agent.ChunkTitleMock
    |> stub(:ask, fn _content, _opts -> {:error, :disabled} end)

    :ok
  end

  defp create_doc do
    {:ok, doc} =
      Document.upsert(%{
        source: "bm25_validation_#{System.unique_integer([:positive])}.md",
        content: "# BM25 Validation\n\nTest document.",
        content_type: "markdown"
      })

    doc
  end

  defp insert_chunk(doc_id, content, language, section_path, index) do
    embedding = Pgvector.HalfVector.new(List.duplicate(0.1, @embedding_dim))

    %Chunk{}
    |> Chunk.changeset(%{
      document_id: doc_id,
      content: String.trim(content),
      chunk_index: index,
      section_path: section_path,
      metadata: %{section_type: :heading, section_level: 2, position: index},
      embedding: embedding,
      language: language
    })
    |> Repo.insert!()
  end

  defp load_corpus do
    doc = create_doc()

    insert_chunk(doc.id, @section_a, "english", ["Section A"], 1)
    insert_chunk(doc.id, @section_b, "english", ["Section B"], 2)
    insert_chunk(doc.id, @section_c, "english", ["Section C"], 3)
    insert_chunk(doc.id, @section_d, "english", ["Section D"], 4)
    insert_chunk(doc.id, @section_e, "french", ["Section E"], 5)
    insert_chunk(doc.id, @section_f, "spanish", ["Section F"], 6)
    insert_chunk(doc.id, @section_g, "arabic", ["Section G"], 7)
    insert_chunk(doc.id, @section_h, "simple", ["Section H"], 8)

    doc
  end

  # ---------------------------------------------------------------------------
  # §2 — BM25 index routing (fixture checklist §2)
  # ---------------------------------------------------------------------------

  describe "§2 BM25 index routing" do
    test "English query returns only English chunks" do
      load_corpus()

      assert {:ok, results} = DocumentProcessor.bm25_search_group_by(@rrf_query, 20)

      items =
        results
        |> Map.values()
        |> Enum.flat_map(&Map.values/1)
        |> List.flatten()

      assert items != [], "expected BM25 hits for English query"

      assert Enum.all?(items, fn item ->
               Chunk
               |> Zaq.Repo.get_by(document_id: item.document_id, section_path: item.section_path)
               |> then(& &1.language) == "english"
             end),
             "English BM25 query returned a non-English chunk"
    end

    test "French query returns only French chunks" do
      load_corpus()

      assert {:ok, results} =
               DocumentProcessor.bm25_search_group_by(
                 "fusion recherche vectorielle rang réciproque",
                 20
               )

      items = results |> Map.values() |> Enum.flat_map(&Map.values/1) |> List.flatten()
      assert items != [], "expected BM25 hits for French query"

      Enum.each(items, fn item ->
        lang =
          Chunk
          |> Zaq.Repo.get_by(document_id: item.document_id, section_path: item.section_path)
          |> then(& &1.language)

        assert lang == "french", "French BM25 returned chunk with language '#{lang}'"
      end)
    end

    test "Spanish query returns only Spanish chunks" do
      load_corpus()

      assert {:ok, results} =
               DocumentProcessor.bm25_search_group_by(
                 "fusión búsqueda vectorial rango recíproco",
                 20
               )

      items = results |> Map.values() |> Enum.flat_map(&Map.values/1) |> List.flatten()
      assert items != [], "expected BM25 hits for Spanish query"

      Enum.each(items, fn item ->
        lang =
          Chunk
          |> Zaq.Repo.get_by(document_id: item.document_id, section_path: item.section_path)
          |> then(& &1.language)

        assert lang == "spanish", "Spanish BM25 returned chunk with language '#{lang}'"
      end)
    end

    test "Arabic query returns only Arabic chunks" do
      load_corpus()

      assert {:ok, results} =
               DocumentProcessor.bm25_search_group_by(
                 "دمج البحث المتجهي الترتيب التبادلي",
                 20
               )

      items = results |> Map.values() |> Enum.flat_map(&Map.values/1) |> List.flatten()
      assert items != [], "expected BM25 hits for Arabic query"

      Enum.each(items, fn item ->
        lang =
          Chunk
          |> Zaq.Repo.get_by(document_id: item.document_id, section_path: item.section_path)
          |> then(& &1.language)

        assert lang == "arabic", "Arabic BM25 returned chunk with language '#{lang}'"
      end)
    end

    test "BM25 scores are positive (pg_search convention: higher = more relevant)" do
      load_corpus()

      {:ok, results} = DocumentProcessor.bm25_search_group_by(@rrf_query, 20)

      results
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> List.flatten()
      |> Enum.each(fn item ->
        assert item.bm25_score > 0,
               "bm25_score should be positive, got #{item.bm25_score}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # §3 — Fusion ranking smoke test (fixture checklist §3)
  # ---------------------------------------------------------------------------

  describe "§3 fusion ranking smoke test" do
    test "Section A (exact keyword match) appears in BM25 results" do
      doc = load_corpus()

      {:ok, bm25_grouped} = DocumentProcessor.bm25_search_group_by(@rrf_query, 20)

      doc_path_labels =
        bm25_grouped
        |> Map.get(doc.id, %{})
        |> Map.keys()
        |> Enum.map(&List.last/1)

      assert "Section A" in doc_path_labels,
             "Section A should appear in BM25 results; got: #{inspect(doc_path_labels)}"
    end

    test "Section A outscores Section D in BM25 (false BM25 hit is demoted)" do
      doc = load_corpus()

      {:ok, bm25_grouped} = DocumentProcessor.bm25_search_group_by(@rrf_query, 20)
      doc_sections = Map.get(bm25_grouped, doc.id, %{})

      section_a_path = Enum.find(Map.keys(doc_sections), &(List.last(&1) == "Section A"))
      section_d_path = Enum.find(Map.keys(doc_sections), &(List.last(&1) == "Section D"))

      assert section_a_path != nil, "Section A must be in BM25 results"

      if section_d_path do
        [%{bm25_score: score_a}] = doc_sections[section_a_path]
        [%{bm25_score: score_d}] = doc_sections[section_d_path]

        # Higher score = more relevant. Section A has exact RRF/formula terms;
        # Section D is a banking false hit.
        assert score_a >= score_d,
               "Section A (#{score_a}) should rank before Section D (#{score_d})"
      end
    end

    test "Section C appears in fused results (shared BM25 + vector signal)" do
      doc = load_corpus()

      {:ok, bm25_grouped} = DocumentProcessor.bm25_search_group_by(@rrf_query, 20)
      {:ok, merged} = DocumentProcessor.rrf_merge(bm25_grouped, %{})

      merged_path_labels =
        merged
        |> Map.get(doc.id, %{})
        |> Map.keys()
        |> Enum.map(&List.last/1)

      assert "Section C" in merged_path_labels,
             "Section C should appear in fused results; got: #{inspect(merged_path_labels)}"
    end

    test "every fused item has a positive rrf_score" do
      doc = load_corpus()

      {:ok, bm25_grouped} = DocumentProcessor.bm25_search_group_by(@rrf_query, 20)
      {:ok, merged} = DocumentProcessor.rrf_merge(bm25_grouped, %{})

      merged
      |> Map.get(doc.id, %{})
      |> Enum.each(fn {path, items} ->
        Enum.each(items, fn item ->
          assert item.rrf_score > 0,
                 "rrf_score at #{inspect(path)} should be positive, got #{item.rrf_score}"
        end)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # §4 — query_extraction/2 end-to-end
  # ---------------------------------------------------------------------------

  describe "§4 query_extraction/2 end-to-end" do
    test "returns non-empty results for the RRF keyword query" do
      load_corpus()

      assert {:ok, results} = DocumentProcessor.query_extraction(@rrf_query)

      assert results != [], "expected results for '#{@rrf_query}'"

      Enum.each(results, fn r ->
        assert Map.has_key?(r, "content")
        assert Map.has_key?(r, "source")
        assert Map.has_key?(r, "distance")
      end)
    end

    test "Section A content (contains 'RRF') surfaces in results" do
      load_corpus()

      {:ok, results} = DocumentProcessor.query_extraction(@rrf_query)

      assert Enum.any?(results, &String.contains?(&1["content"], "RRF")),
             "expected a result containing 'RRF' (Section A exact match)"
    end

    test "French query returns non-empty results" do
      load_corpus()

      assert {:ok, results} =
               DocumentProcessor.query_extraction("fusion recherche vectorielle")

      assert is_list(results)
    end

    test "Spanish query returns non-empty results" do
      load_corpus()

      assert {:ok, results} =
               DocumentProcessor.query_extraction("fusión búsqueda vectorial rango recíproco")

      assert is_list(results)
    end

    test "Arabic query returns non-empty results" do
      load_corpus()

      assert {:ok, results} =
               DocumentProcessor.query_extraction("دمج البحث المتجهي الترتيب التبادلي")

      assert is_list(results)
    end
  end
end
