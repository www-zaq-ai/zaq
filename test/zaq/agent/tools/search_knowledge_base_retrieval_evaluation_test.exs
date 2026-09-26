defmodule Zaq.Agent.Tools.SearchKnowledgeBaseRetrievalEvaluationTest do
  @moduledoc """
  Offline relevance regression through real NodeRouter, SQL, fusion and hydration.

  Uses the isolated 3584-dimensional test partition documented in the retrieval
  evaluation guide. The only external boundaries are translation generation and
  the embedding HTTP provider; unknown semantic inputs fail closed.
  """

  use Zaq.DataCase, async: false

  @moduletag :integration
  @moduletag capture_log: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.RetrievalEval.Fixtures
  alias Zaq.Agent.Tools.SearchKnowledgeBase
  alias Zaq.Ingestion.{Chunk, ChunkLanguages, Document, FTSBackend}
  alias Zaq.Permissions
  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures
  alias Zaq.TestSupport.OpenAIStub

  @dimension 3584
  @evaluation_threshold 0.45
  @root Fixtures.default_path()

  defmodule FixtureGeneration do
    @moduledoc "Generates a deterministic, pre-reviewed translation from the fixture question."
    alias Mix.Tasks.RetrievalEval.Fixtures

    def generate_text(_spec, [message], _opts) do
      prompt = Enum.map_join(message.content, "", & &1.text) |> Jason.decode!()

      question =
        Fixtures.load!()
        |> Map.fetch!(:questions)
        |> Enum.find(&(&1.data["question"] == prompt["query"]))

      if is_nil(question),
        do: raise("No retrieval evaluation question for #{inspect(prompt["query"])}")

      variants =
        Map.new(prompt["languages"], fn language ->
          variant = Map.fetch!(question.data["variants"], language)

          {language,
           %{
             semantic_query: variant["semantic_query"],
             lexical_terms: Enum.map(variant["lexical_groups"], &Enum.join(&1, " "))
           }}
        end)

      {:ok,
       %ReqLLM.Response{
         id: "fixture-translation",
         model: "fixture-translation",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant(Jason.encode!(variants))
       }}
    end
  end

  setup_all do
    partition = System.get_env("MIX_TEST_PARTITION")

    unless partition in ~w(retrieval_eval_native retrieval_eval_parade) do
      raise "Use MIX_TEST_PARTITION=retrieval_eval_native (or retrieval_eval_parade) for this 3584-dimensional suite; never alter the shared test database"
    end

    Sandbox.mode(Repo, :auto)

    try do
      case Repo.query!("SELECT to_regclass('public.chunks')", []).rows do
        [[nil]] ->
          Chunk.create_table(@dimension)

        [[_]] ->
          %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM chunks", [])

          if count != 0,
            do:
              raise(
                "Retrieval evaluation requires an empty dedicated test partition; found #{count} chunks"
              )

          %{rows: [[type]]} =
            Repo.query!(
              "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'chunks'::regclass AND attname = 'embedding'",
              []
            )

          unless type == "halfvec(#{@dimension})" do
            Repo.query!(
              "ALTER TABLE chunks ALTER COLUMN embedding TYPE halfvec(#{@dimension}) USING embedding::halfvec(#{@dimension})",
              []
            )
          end

          Chunk.create_table(@dimension)
      end

      if partition == "retrieval_eval_parade" do
        if FTSBackend.detect_and_cache() != FTSBackend.ParadeDB,
          do: raise("ParadeDB backend unavailable in retrieval_eval_parade partition")
      else
        :persistent_term.put({FTSBackend, :backend}, FTSBackend.Native)
      end
    after
      Sandbox.mode(Repo, :manual)
    end

    on_exit(fn -> FTSBackend.reset_cache() end)

    :ok
  end

  setup do
    fixtures = Fixtures.load!(@root, :evaluate)
    assert fixtures.embedding_space == {"bge-multilingual-gemma2", @dimension}

    SystemConfigFixtures.seed_embedding_config(%{
      model: "bge-multilingual-gemma2",
      dimension: @dimension
    })

    SystemConfigFixtures.seed_llm_config(%{max_cosine_distance: @evaluation_threshold})

    doc_ids = seed_documents!(fixtures.documents)
    ChunkLanguages.invalidate()

    vectors =
      Map.new(
        for %{data: data} <- fixtures.questions, variant <- Map.values(data["variants"]) do
          {variant["semantic_query"], variant["embedding"]}
        end
      )

    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => input} = Jason.decode!(body)
      vector = Map.fetch!(vectors, input)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"embedding" => vector}]}))
    end)

    %{fixtures: fixtures, doc_ids: doc_ids}
  end

  for path <- Path.wildcard(Path.join(@root, "questions/*.json")) |> Enum.sort() do
    id = Path.basename(path, ".json")

    test "retrieval evaluation: #{id}", %{fixtures: fixtures, doc_ids: doc_ids} do
      question = Enum.find(fixtures.questions, &(&1.data["id"] == unquote(id))).data
      config = OpenAIStub.llm_config("http://example.test/v1") |> Map.new()

      lexical_terms =
        question["variants"]
        |> Map.values()
        |> Enum.flat_map(& &1["lexical_groups"])
        |> Enum.map(&Enum.join(&1, " "))
        |> Enum.uniq()

      assert {:ok, result} =
               Jido.Exec.run(
                 SearchKnowledgeBase,
                 %{query: question["question"], lexical_terms: lexical_terms},
                 %{
                   generation: FixtureGeneration,
                   llm_config: config,
                   person_id: nil
                 }
               )

      assert result.errors == []
      refute result.partial
      assert result.count == length(result.chunks)
      assert Enum.all?(result.chunks, &(!Map.has_key?(&1, "distance")))

      returned =
        Map.new(result.chunks, fn chunk ->
          {{chunk["document_id"], chunk["chunk_index"]}, chunk}
        end)

      assert map_size(returned) == result.count, "retrieval returned duplicate chunk identities"

      if question["expected"] == [], do: assert(result.count == 0)

      for expected <- question["expected"] do
        doc = Enum.find(fixtures.documents, &(&1.data["id"] == expected["document_id"])).data
        fixture_chunk = Enum.find(doc["chunks"], &(&1["id"] == expected["chunk_id"]))
        identity = {Map.fetch!(doc_ids, doc["id"]), fixture_chunk["index"]}
        actual = Map.fetch!(returned, identity)

        assert actual["content"] == fixture_chunk["content"]
        assert actual["language"] == expected["language"]
        assert Enum.all?(expected["legs"], &(&1 in actual["retrieval_legs"]))

        case expected["vector_distance"] do
          [min_distance, max_distance] ->
            assert is_number(actual["vector_distance"])
            assert actual["vector_distance"] >= min_distance
            assert actual["vector_distance"] <= max_distance

          nil ->
            assert actual["vector_distance"] == nil
        end
      end

      if question["expected"] != [] do
        assert question["forbidden"] != [],
               "#{question["id"]}: positive evaluations must name irrelevant chunks to exclude"
      end

      for forbidden <- question["forbidden"] do
        doc = Enum.find(fixtures.documents, &(&1.data["id"] == forbidden["document_id"])).data
        fixture_chunk = Enum.find(doc["chunks"], &(&1["id"] == forbidden["chunk_id"]))

        refute Map.has_key?(returned, {Map.fetch!(doc_ids, doc["id"]), fixture_chunk["index"]}),
               "#{question["id"]}: irrelevant chunk #{doc["id"]}/#{fixture_chunk["id"]} was returned"
      end
    end
  end

  defp seed_documents!(entries) do
    Map.new(entries, fn %{data: data} ->
      {:ok, doc} =
        Document.upsert(%{
          source: "retrieval_eval/#{data["id"]}.md",
          title: data["title"],
          content: data["markdown"],
          content_type: "markdown"
        })

      {:ok, _} = Permissions.grant_public(doc)

      Enum.each(data["chunks"], fn chunk ->
        {:ok, _} =
          Chunk.create_with_embedding(
            %{
              document_id: doc.id,
              content: chunk["content"],
              chunk_index: chunk["index"],
              section_path: chunk["section_path"],
              language: chunk["language"],
              metadata: %{fixture_id: chunk["id"]}
            },
            chunk["embedding"]
          )
      end)

      {data["id"], doc.id}
    end)
  end
end
