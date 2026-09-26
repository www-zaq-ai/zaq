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

      assert question.data["question"] ==
               "Do I need permission to ride in the premium carriage for a client visit?"

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

  test "deduplicates identical missing chunk and semantic-query texts" do
    with_fixture_copy(fn root ->
      document_path = Path.join(root, "documents/english-travel.json")
      document = document_path |> File.read!() |> Jason.decode!()
      [first | rest] = document["chunks"]
      duplicate = Map.put(Enum.at(rest, 0), "content", first["content"])
      chunks = List.replace_at(document["chunks"], 1, duplicate)
      File.write!(document_path, Jason.encode!(Map.put(document, "chunks", chunks)))
      question_path = Path.join(root, "questions/english-travel.json")
      question_before = question_path |> File.read!() |> Jason.decode!()

      calls = :ets.new(:embedding_calls, [:duplicate_bag, :public])

      embed = fn text ->
        :ets.insert(calls, {text, make_ref()})
        {:ok, [1.0, 0.0]}
      end

      assert %{updated: 4, embedded: count} =
               Embed.prepare!(root, "test-model", 2, embed)

      assert length(:ets.lookup(calls, first["content"])) == 1
      assert :ets.info(calls, :size) == count

      unique_provider_inputs =
        calls |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      assert length(unique_provider_inputs) == count

      before_rerun = Map.new(fixture_json_files(root), &{&1, File.read!(&1)})

      assert %{updated: 0, embedded: 0} =
               Embed.prepare!(root, "test-model", 2, fn _ ->
                 flunk("unexpected embedding call on idempotent rerun")
               end)

      assert Map.new(fixture_json_files(root), &{&1, File.read!(&1)}) == before_rerun

      %{documents: documents, questions: [question]} = Fixtures.load!(root, :prepare)
      persisted = Enum.find(documents, &(&1.data["id"] == "english-travel"))
      duplicated_chunks = Enum.take(persisted.data["chunks"], 2)
      assert Enum.map(duplicated_chunks, & &1["embedding"]) == [[1.0, 0.0], [1.0, 0.0]]

      expected_hash = Fixtures.input_hash(first["content"])

      assert Enum.all?(duplicated_chunks, fn chunk ->
               chunk["embedding_provenance"]["input_sha256"] == expected_hash
             end)

      for field <- ~w(expected forbidden question) do
        assert question.data[field] == question_before[field]
      end
    end)
  end

  test "invalid successful provider vectors leave every fixture byte unchanged" do
    for {label, invalid_vector, error} <- [
          {"wrong dimension", [1.0], ~r/invalid embedding response.*2 coordinates/},
          {"zero norm", [0.0, 0.0], ~r/zero-norm embedding/}
        ] do
      with_fixture_copy(fn root ->
        files = fixture_json_files(root)
        before = Map.new(files, &{&1, File.read!(&1)})
        calls = :atomics.new(1, [])

        assert_raise ArgumentError, error, fn ->
          Embed.prepare!(root, "test-model", 2, fn _text ->
            if :atomics.add_get(calls, 1, 1) == 1,
              do: {:ok, [1.0, 0.0]},
              else: {:ok, invalid_vector}
          end)
        end

        assert Map.new(files, &{&1, File.read!(&1)}) == before,
               "#{label} response changed fixture bytes"

        assert Enum.all?(files, fn path -> Path.wildcard(path <> ".tmp-*") == [] end)
      end)
    end
  end

  test "reports committed paths when a later fixture rename fails" do
    with_fixture_copy(fn root ->
      question_path = Path.join(root, "questions/english-travel.json")
      backup_path = question_path <> ".backup"
      original_question = File.read!(question_path)

      source_paths =
        for name <- ~w(english-travel french-equipment arabic-leave),
            do: Path.join(root, "documents/#{name}.json")

      calls = :atomics.new(1, [])

      try do
        error =
          assert_raise ArgumentError, fn ->
            Embed.prepare!(root, "test-model", 2, fn _text ->
              if :atomics.add_get(calls, 1, 1) == 1 do
                File.rename!(question_path, backup_path)
                File.mkdir!(question_path)
              end

              {:ok, [1.0, 0.0]}
            end)
          end

        assert Exception.message(error) =~ question_path
        assert Exception.message(error) =~ "fixture rename failed"
        assert Exception.message(error) =~ inspect(Enum.sort(source_paths))

        assert Enum.all?(source_paths, fn path ->
                 data = path |> File.read!() |> Jason.decode!()
                 Enum.all?(data["chunks"], &(&1["embedding"] == [1.0, 0.0]))
               end)

        assert File.read!(backup_path) == original_question

        assert fixture_directories(root)
               |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.tmp-*"))) == []
      after
        if File.dir?(question_path), do: File.rm_rf!(question_path)
        if File.exists?(backup_path), do: File.rename!(backup_path, question_path)
      end
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
        data
        |> Map.put("forbidden", [])
        |> Map.update!(
          "variants",
          &Map.new(&1, fn {lang, variant} ->
            {lang, Map.merge(variant, %{"embedding" => nil, "embedding_provenance" => nil})}
          end)
        )
      end

    File.write!(path, Jason.encode!(data))
  end

  defp fixture_json_files(root) do
    for kind <- ~w(documents questions),
        path <- Path.wildcard(Path.join(root, "#{kind}/*.json")),
        do: path
  end

  defp fixture_directories(root),
    do: Enum.map(~w(documents questions), &Path.join(root, &1))
end
