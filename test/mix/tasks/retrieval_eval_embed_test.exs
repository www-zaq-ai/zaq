defmodule Mix.Tasks.RetrievalEval.EmbedTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.RetrievalEval.Embed
  alias Mix.Tasks.RetrievalEval.Fixtures

  @source Fixtures.default_path()

  test "fills missing vectors with exact semantic and chunk texts; second run is idempotent" do
    with_fixture_copy(fn root ->
      texts = :ets.new(:embedding_calls, [:set, :public])

      embed = fn text ->
        :ets.insert(texts, {text, true})
        {:ok, [1.0, 0.0]}
      end

      assert %{updated: 4, embedded: count} = Embed.prepare!(root, "test-model", 2, embed)
      assert count > 0
      assert :ets.info(texts, :size) == count

      assert %{updated: 0, embedded: 0} =
               Embed.prepare!(root, "test-model", 2, fn _ ->
                 flunk("unexpected embedding call")
               end)

      %{documents: documents, questions: [question]} = Fixtures.load!(root, :prepare)
      doc = Enum.find(documents, &(&1.data["id"] == "english-travel"))
      assert Enum.all?(doc.data["chunks"], &(&1["embedding"] == [1.0, 0.0]))
      assert question.data["question"] == "Can I take a first-class train to a client meeting?"
      assert question.data["expected"] != []

      assert question.data["variants"]["english"]["embedding_provenance"]["input_sha256"] ==
               Fixtures.input_hash(question.data["variants"]["english"]["semantic_query"])
    end)
  end

  test "provider errors never write a partial set of files" do
    with_fixture_copy(fn root ->
      files =
        for kind <- ~w(documents questions),
            path <- Path.wildcard(Path.join(root, "#{kind}/*.json")),
            do: path

      before = Map.new(files, &{&1, File.read!(&1)})
      calls = :atomics.new(1, [])

      assert_raise ArgumentError, ~r/embedding request failed/, fn ->
        Embed.prepare!(root, "test-model", 2, fn _ ->
          if :atomics.add_get(calls, 1, 1) == 2,
            do: {:error, :unavailable},
            else: {:ok, [1.0, 0.0]}
        end)
      end

      assert Map.new(files, &{&1, File.read!(&1)}) == before
    end)
  end

  test "stale vectors or model mismatch require an explicit refresh" do
    with_fixture_copy(fn root ->
      Embed.prepare!(root, "test-model", 2, fn _ -> {:ok, [1.0, 0.0]} end)

      assert_raise ArgumentError, ~r/model.*mismatch|mixed models/, fn ->
        Embed.prepare!(root, "other-model", 2, fn _ -> flunk("unexpected call") end)
      end

      assert %{embedded: count} =
               Embed.prepare!(root, "other-model", 2, fn _ -> {:ok, [0.0, 1.0]} end,
                 refresh: true
               )

      assert count > 0
    end)
  end

  defp with_fixture_copy(fun) do
    root = Path.join(System.tmp_dir!(), "retrieval_embed_#{System.unique_integer([:positive])}")

    for kind <- ~w(documents questions) do
      File.mkdir_p!(Path.join(root, kind))
    end

    File.cp!(
      Path.join(@source, "documents/english-travel.json"),
      Path.join(root, "documents/english-travel.json")
    )

    File.cp!(
      Path.join(@source, "questions/english-travel.json"),
      Path.join(root, "questions/english-travel.json")
    )

    # The question requires three corpus languages.
    for name <- ~w(french-equipment arabic-leave) do
      File.cp!(
        Path.join(@source, "documents/#{name}.json"),
        Path.join(root, "documents/#{name}.json")
      )
    end

    for kind <- ~w(documents questions),
        path <- Path.wildcard(Path.join(root, "#{kind}/*.json")) do
      clear_embeddings(path, kind)
    end

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  defp clear_embeddings(path, kind) do
    data = path |> File.read!() |> Jason.decode!()

    data =
      if kind == "documents" do
        Map.update!(data, "chunks", fn chunks ->
          Enum.map(chunks, &Map.merge(&1, %{"embedding" => nil, "embedding_provenance" => nil}))
        end)
      else
        Map.update!(
          data,
          "variants",
          &Map.new(&1, fn {lang, variant} ->
            {lang, Map.merge(variant, %{"embedding" => nil, "embedding_provenance" => nil})}
          end)
        )
      end

    File.write!(path, Jason.encode!(data))
  end
end
