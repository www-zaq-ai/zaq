defmodule Mix.Tasks.RetrievalEval.FixturesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Mix.Tasks.RetrievalEval.Fixtures

  @root Path.expand("../../fixtures/retrieval", __DIR__)

  test "preparation accepts authored fixtures; evaluation names missing vector and remediation" do
    assert %{documents: documents, questions: questions} = Fixtures.load!(@root, :prepare)
    assert length(documents) == 4
    assert length(questions) == 11

    in_tmp(fn root ->
      doc = document(root)
      [first | rest] = doc["chunks"]
      first = %{first | "embedding" => nil, "embedding_provenance" => nil}
      write_doc(root, %{doc | "chunks" => [first | rest]})

      assert_raise ArgumentError, ~r/embedding.*missing.*mix retrieval\.eval\.embed/s, fn ->
        Fixtures.load!(root, :evaluate)
      end
    end)
  end

  test "rejects duplicate chunk IDs with a file and field path" do
    in_tmp(fn root ->
      doc = document(root)
      [first | _] = doc["chunks"]
      write_doc(root, %{doc | "chunks" => [first, first]})

      assert_raise ArgumentError, ~r/english-travel\.json.*chunks.*duplicate/s, fn ->
        Fixtures.load!(root, :prepare)
      end
    end)
  end

  test "rejects unresolved expectations and stale vector provenance" do
    in_tmp(fn root ->
      question = question(root)

      expected = [
        %{
          "document_id" => "does-not-exist",
          "chunk_id" => "nope",
          "language" => "english",
          "legs" => ["vector"],
          "vector_distance" => [0.1, 0.2]
        }
      ]

      write_question(root, %{question | "expected" => expected})

      assert_raise ArgumentError, ~r/english-travel\.json.*expected.*unknown/s, fn ->
        Fixtures.load!(root, :prepare)
      end
    end)

    in_tmp(fn root ->
      doc = document(root)
      [first | rest] = doc["chunks"]

      first =
        Map.merge(first, %{
          "embedding" => [0.1, 0.2],
          "embedding_provenance" => %{
            "model" => "test",
            "dimension" => 2,
            "input_sha256" => "stale"
          }
        })

      write_doc(root, %{doc | "chunks" => [first | rest]})

      assert_raise ArgumentError, ~r/english-travel\.json.*input_sha256.*stale/s, fn ->
        Fixtures.load!(root, :prepare)
      end
    end)
  end

  property "a nonzero finite vector is valid and input hashing is deterministic" do
    check all(
            coordinates <- list_of(float(min: -100.0, max: 100.0), length: 3),
            max_runs: 25
          ) do
      vector = [1.0 | coordinates]
      assert :ok = Fixtures.validate_vector(vector, length(vector))
      assert Fixtures.input_hash(inspect(vector)) == Fixtures.input_hash(inspect(vector))
    end
  end

  test "rejects a vector that becomes zero when stored as halfvec" do
    assert {:error, "embedding rounds to zero in halfvec"} =
             Fixtures.validate_vector([1.0e-12, 0.0], 2)
  end

  test "missing semantic-query vectors fail with the question filename and field" do
    in_tmp(fn root ->
      data = question(root)
      variants = put_in(data, ["variants", "french", "embedding"], nil)
      variants = put_in(variants, ["variants", "french", "embedding_provenance"], nil)
      write_question(root, variants)

      assert_raise ArgumentError,
                   ~r/questions\/english-travel\.json: variants\.french\.embedding: missing.*mix retrieval\.eval\.embed/,
                   fn -> Fixtures.load!(root, :evaluate) end
    end)
  end

  test "rejects malformed JSON, invalid lexical groups and unreviewed expectations" do
    in_tmp(fn root ->
      path = Path.join(root, "questions/english-travel.json")
      File.write!(path, "{broken")

      assert_raise ArgumentError, ~r/english-travel\.json: \$: invalid JSON/, fn ->
        Fixtures.load!(root, :prepare)
      end
    end)

    in_tmp(fn root ->
      data = question(root)
      write_question(root, put_in(data, ["variants", "english", "lexical_groups"], [[]]))

      assert_raise ArgumentError, ~r/variants\.english\.lexical_groups/, fn ->
        Fixtures.load!(root, :prepare)
      end
    end)

    in_tmp(fn root ->
      data = question(root)
      write_question(root, %{data | "ranges_reviewed" => false})

      assert_raise ArgumentError, ~r/ranges_reviewed: review expected results/, fn ->
        Fixtures.load!(root, :evaluate)
      end
    end)
  end

  defp in_tmp(fun) do
    root = Path.join(System.tmp_dir!(), "retrieval_eval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "documents"))
    File.mkdir_p!(Path.join(root, "questions"))

    @root
    |> Path.join("documents/*.json")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      File.cp!(path, Path.join(root, "documents/#{Path.basename(path)}"))
    end)

    File.cp!(
      Path.join(@root, "questions/english-travel.json"),
      Path.join(root, "questions/english-travel.json")
    )

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  defp document(root),
    do: root |> Path.join("documents/english-travel.json") |> File.read!() |> Jason.decode!()

  defp question(root),
    do: root |> Path.join("questions/english-travel.json") |> File.read!() |> Jason.decode!()

  defp write_doc(root, data),
    do: File.write!(Path.join(root, "documents/english-travel.json"), Jason.encode!(data))

  defp write_question(root, data),
    do: File.write!(Path.join(root, "questions/english-travel.json"), Jason.encode!(data))
end
