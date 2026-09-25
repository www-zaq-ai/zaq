defmodule Mix.Tasks.RetrievalEval.Fixtures do
  @moduledoc """
  Loads and validates the offline multilingual retrieval evaluation fixtures.

  `:prepare` accepts missing vectors while `:evaluate` requires complete vectors
  and reviewed relevance ranges. Paths in errors point to the offending JSON field.
  This module is developer tooling, not a runtime Action or agent tool.
  """

  @languages ~w(english french arabic)
  @remedy "Run mix retrieval.eval.embed to populate missing vectors."

  @doc "The checked-in dataset directory, independently discoverable by the Mix task and tests."
  def default_path, do: Path.expand("../../../../test/fixtures/retrieval", __DIR__)

  @doc "Returns document and question entries of the form `%{path: path, data: json}`."
  def load!(root \\ default_path(), mode \\ :evaluate)
      when mode in [:prepare, :evaluate, :refresh] do
    documents = read_files!(root, "documents")
    questions = read_files!(root, "questions")
    assert!(documents != [], root, "documents", "no documents found")
    assert!(questions != [], root, "questions", "no questions found")

    Enum.each(documents, &validate_document!(&1, mode))
    Enum.each(questions, &validate_question!(&1, mode))
    unique!(documents, "id")
    unique!(questions, "id")

    chunks =
      Map.new(
        for %{data: doc} <- documents, chunk <- doc["chunks"] do
          {{doc["id"], chunk["id"]}, chunk}
        end
      )

    doc_languages =
      documents
      |> Enum.flat_map(fn %{data: doc} -> Enum.map(doc["chunks"], & &1["language"]) end)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.each(questions, &validate_references!(&1, chunks, doc_languages))

    provenances =
      for entry <- documents ++ questions,
          item <-
            if(Map.has_key?(entry.data, "chunks"),
              do: entry.data["chunks"],
              else: Map.values(entry.data["variants"])
            ),
          provenance = item["embedding_provenance"],
          not is_nil(provenance),
          do: {provenance["model"], provenance["dimension"]}

    if mode != :refresh do
      assert!(
        length(Enum.uniq(provenances)) <= 1,
        root,
        "embedding_provenance",
        "mixed models or dimensions"
      )
    end

    %{documents: documents, questions: questions, embedding_space: List.first(provenances)}
  end

  @doc "Stable SHA-256 of the exact text sent to the embedding provider."
  def input_hash(text) when is_binary(text),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  @doc "Checks vector dimension, finite coordinates, halfvec limits and nonzero norm."
  def validate_vector(vector, dimension)
      when is_list(vector) and is_integer(dimension) and dimension > 0 do
    cond do
      length(vector) != dimension ->
        {:error, "expected #{dimension} coordinates"}

      not Enum.all?(vector, &valid_coordinate?/1) ->
        {:error, "coordinates must be finite halfvec numbers"}

      Enum.all?(vector, &(&1 == 0)) ->
        {:error, "zero-norm embedding"}

      zero_after_halfvec?(vector) ->
        {:error, "embedding rounds to zero in halfvec"}

      true ->
        :ok
    end
  end

  def validate_vector(_, _),
    do: {:error, "expected a nonempty numeric vector and positive dimension"}

  defp valid_coordinate?(coordinate),
    do: is_number(coordinate) and abs(coordinate) <= 65_504

  defp zero_after_halfvec?(vector),
    do: vector |> Pgvector.HalfVector.new() |> Pgvector.to_list() |> Enum.all?(&(&1 == 0))

  defp validate_references!(%{path: path, data: data}, chunks, languages) do
    assert!(
      Enum.sort(Map.keys(data["variants"])) == languages,
      path,
      "variants",
      "expected #{inspect(languages)}"
    )

    Enum.each(data["expected"], fn expected ->
      key = {expected["document_id"], expected["chunk_id"]}
      actual = Map.get(chunks, key)
      assert!(not is_nil(actual), path, "expected", "unknown chunk #{inspect(key)}")

      assert!(
        expected["language"] == actual["language"],
        path,
        "expected.language",
        "does not match stored chunk language"
      )
    end)

    Enum.each(data["forbidden"], fn forbidden ->
      key = {forbidden["document_id"], forbidden["chunk_id"]}
      assert!(Map.has_key?(chunks, key), path, "forbidden", "unknown chunk #{inspect(key)}")
    end)
  end

  defp read_files!(root, kind) do
    directory = Path.join(root, kind)
    assert!(File.dir?(directory), directory, kind, "directory missing")

    directory
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&read_file!/1)
  end

  defp read_file!(path) do
    case File.read(path) do
      {:ok, json} -> decode_file!(path, json)
      {:error, reason} -> fail!(path, "$", "cannot read: #{inspect(reason)}")
    end
  end

  defp decode_file!(path, json) do
    case Jason.decode(json) do
      {:ok, data} when is_map(data) -> %{path: path, data: data}
      _ -> fail!(path, "$", "invalid JSON object")
    end
  end

  defp validate_document!(%{path: path, data: data}, mode) do
    version!(path, data)
    nonempty!(path, "id", data["id"])
    nonempty!(path, "title", data["title"])
    nonempty!(path, "markdown", data["markdown"])
    assert!(data["language"] in (@languages ++ ["mixed"]), path, "language", "unsupported")

    assert!(
      is_list(data["chunks"]) and data["chunks"] != [],
      path,
      "chunks",
      "expected a nonempty array"
    )

    ids = Enum.map(data["chunks"], & &1["id"])
    assert!(length(Enum.uniq(ids)) == length(ids), path, "chunks", "duplicate chunk ID")

    Enum.with_index(data["chunks"])
    |> Enum.each(fn {chunk, index} ->
      field = "chunks[#{index}]"
      assert!(is_map(chunk), path, field, "expected an object")
      nonempty!(path, field <> ".id", chunk["id"])
      assert!(chunk["index"] == index, path, field <> ".index", "must be #{index}")
      assert!(chunk["language"] in @languages, path, field <> ".language", "unsupported")
      nonempty!(path, field <> ".content", chunk["content"])

      assert!(
        String.contains?(data["markdown"], chunk["content"]),
        path,
        field <> ".content",
        "not present verbatim in markdown"
      )

      assert!(
        is_list(chunk["section_path"]) and chunk["section_path"] != [] and
          Enum.all?(chunk["section_path"], &is_binary/1),
        path,
        field <> ".section_path",
        "expected nonempty string array"
      )

      vector!(path, field, chunk, chunk["content"], mode)
    end)
  end

  defp validate_question!(%{path: path, data: data}, mode) do
    version!(path, data)
    nonempty!(path, "id", data["id"])
    nonempty!(path, "question", data["question"])
    nonempty!(path, "scenario", data["scenario"])
    assert!(is_map(data["variants"]), path, "variants", "expected language map")
    assert!(is_list(data["expected"]), path, "expected", "expected array")
    assert!(is_list(data["forbidden"]), path, "forbidden", "expected array")

    Enum.each(data["variants"], fn {language, variant} ->
      validate_variant!(path, language, variant, mode)
    end)

    Enum.each(data["expected"], &validate_expected!(path, &1))

    Enum.each(data["forbidden"], fn forbidden ->
      assert!(is_map(forbidden), path, "forbidden", "expected object")
      nonempty!(path, "forbidden.document_id", forbidden["document_id"])
      nonempty!(path, "forbidden.chunk_id", forbidden["chunk_id"])
    end)

    if mode == :evaluate,
      do:
        assert!(
          data["ranges_reviewed"] == true,
          path,
          "ranges_reviewed",
          "review expected results before evaluation"
        )
  end

  defp validate_variant!(path, language, variant, mode) do
    field = "variants.#{language}"

    assert!(
      language in @languages and is_map(variant),
      path,
      field,
      "unsupported language or invalid variant"
    )

    nonempty!(path, field <> ".semantic_query", variant["semantic_query"])
    groups = variant["lexical_groups"]

    assert!(
      is_list(groups) and groups != [] and
        Enum.all?(
          groups,
          &(is_list(&1) and &1 != [] and
              Enum.all?(&1, fn word -> is_binary(word) and String.trim(word) != "" end))
        ),
      path,
      field <> ".lexical_groups",
      "expected nonempty groups of nonblank strings"
    )

    vector!(path, field, variant, variant["semantic_query"], mode)
  end

  defp validate_expected!(path, expected) do
    assert!(is_map(expected), path, "expected", "expected an object")
    nonempty!(path, "expected.document_id", expected["document_id"])
    nonempty!(path, "expected.chunk_id", expected["chunk_id"])
    assert!(expected["language"] in @languages, path, "expected.language", "unsupported")
    legs = expected["legs"]

    assert!(
      is_list(legs) and legs != [] and Enum.all?(legs, &(&1 in ~w(vector lexical))),
      path,
      "expected.legs",
      "expected vector and/or lexical"
    )

    range = expected["vector_distance"]

    valid? =
      if "vector" in legs, do: valid_range?(range), else: is_nil(range) or valid_range?(range)

    assert!(
      valid?,
      path,
      "expected.vector_distance",
      "expected inclusive numeric range within [0, 2] for vector matches"
    )
  end

  defp vector!(path, field, item, text, mode) do
    vector = item["embedding"]
    provenance = item["embedding_provenance"]

    if mode == :refresh do
      :ok
    else
      validate_stored_vector!(path, field, vector, provenance, text, mode)
    end
  end

  defp validate_stored_vector!(path, field, vector, provenance, text, mode) do
    if is_nil(vector) do
      assert!(
        is_nil(provenance),
        path,
        field <> ".embedding_provenance",
        "present without embedding"
      )

      if mode == :evaluate, do: fail!(path, field <> ".embedding", "missing. #{@remedy}")
    else
      assert!(is_map(provenance), path, field <> ".embedding_provenance", "missing")
      nonempty!(path, field <> ".embedding_provenance.model", provenance["model"])
      dimension = provenance["dimension"]

      case validate_vector(vector, dimension) do
        :ok -> :ok
        {:error, reason} -> fail!(path, field <> ".embedding", reason)
      end

      assert!(
        provenance["input_sha256"] == input_hash(text),
        path,
        field <> ".embedding_provenance.input_sha256",
        "stale input hash"
      )

      assert!(
        provenance["vector_sha256"] == input_hash(Jason.encode!(vector)),
        path,
        field <> ".embedding_provenance.vector_sha256",
        "stale vector hash"
      )
    end
  end

  defp valid_range?([min, max]) when is_number(min) and is_number(max),
    do: min >= 0 and max <= 2 and min <= max

  defp valid_range?(_), do: false

  defp version!(path, data),
    do: assert!(data["schema_version"] == 1, path, "schema_version", "unsupported")

  defp nonempty!(path, field, value),
    do:
      assert!(
        is_binary(value) and String.trim(value) != "",
        path,
        field,
        "expected nonblank string"
      )

  defp assert!(true, _path, _field, _message), do: :ok
  defp assert!(false, path, field, message), do: fail!(path, field, message)
  defp fail!(path, field, message), do: raise(ArgumentError, "#{path}: #{field}: #{message}")

  defp unique!(entries, field) do
    Enum.reduce(entries, MapSet.new(), fn %{path: path, data: data}, seen ->
      id = data[field]
      assert!(not MapSet.member?(seen, id), path, field, "duplicate #{id}")
      MapSet.put(seen, id)
    end)
  end
end
