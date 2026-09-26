defmodule Mix.Tasks.RetrievalEval.Embed do
  @moduledoc """
  Prepares versioned retrieval evaluation JSON without altering judged expectations.

  The Mix task supplies the configured client. This local-only helper stages all
  provider responses before modifying fixture files, so a provider failure never
  leaves a partly embedded corpus. Per-file writes use a sibling temp and rename.
  """

  alias Mix.Tasks.RetrievalEval.Fixtures

  @doc "Fills missing (or, with `:refresh`, all) embeddings from an injected provider."
  def prepare!(root, model, dimension, embed, opts \\ [])
      when is_binary(model) and is_integer(dimension) and is_function(embed, 1) do
    refresh? = Keyword.get(opts, :refresh, false)
    fixtures = Fixtures.load!(root, if(refresh?, do: :refresh, else: :prepare))

    if not refresh? and fixtures.embedding_space not in [nil, {model, dimension}] do
      raise ArgumentError,
            "#{root}: embedding model or dimension mismatch; use mix retrieval.eval.embed --refresh to regenerate all vectors"
    end

    {entries, cache} =
      Enum.map_reduce(fixtures.documents ++ fixtures.questions, %{}, fn entry, cache ->
        prepare_entry!(entry, cache, model, dimension, embed, refresh?)
      end)

    changed = Enum.filter(entries, fn %{data: data, original: original} -> data != original end)
    paths = write_changed!(changed)
    %{embedded: map_size(cache), updated: length(paths), paths: paths}
  end

  defp prepare_entry!(%{path: path, data: data}, cache, model, dimension, embed, refresh?) do
    original = data

    {data, cache} =
      if Map.has_key?(data, "chunks") do
        {chunks, cache} =
          Enum.map_reduce(data["chunks"], cache, fn chunk, acc ->
            fill!(chunk, chunk["content"], path, acc, model, dimension, embed, refresh?)
          end)

        {Map.put(data, "chunks", chunks), cache}
      else
        {variants, cache} =
          Enum.reduce(data["variants"], {%{}, cache}, fn {language, variant}, {acc, vectors} ->
            {variant, vectors} =
              fill!(
                variant,
                variant["semantic_query"],
                path,
                vectors,
                model,
                dimension,
                embed,
                refresh?
              )

            {Map.put(acc, language, variant), vectors}
          end)

        {Map.put(data, "variants", variants), cache}
      end

    {%{path: path, data: data, original: original}, cache}
  end

  defp fill!(item, text, path, cache, model, dimension, embed, refresh?) do
    if not refresh? and not is_nil(item["embedding"]) do
      {item, cache}
    else
      {vector, cache} =
        case Map.fetch(cache, text) do
          {:ok, vector} ->
            {vector, cache}

          :error ->
            vector = request_vector!(embed, text, path, dimension)
            {vector, Map.put(cache, text, vector)}
        end

      provenance = %{
        "model" => model,
        "dimension" => dimension,
        "input_sha256" => Fixtures.input_hash(text),
        "vector_sha256" => Fixtures.input_hash(Jason.encode!(vector))
      }

      {Map.merge(item, %{"embedding" => vector, "embedding_provenance" => provenance}), cache}
    end
  end

  defp request_vector!(embed, text, path, dimension) do
    case embed.(text) do
      {:ok, vector} ->
        case Fixtures.validate_vector(vector, dimension) do
          :ok ->
            vector

          {:error, reason} ->
            raise ArgumentError, "#{path}: invalid embedding response: #{reason}"
        end

      {:error, reason} ->
        raise ArgumentError, "#{path}: embedding request failed: #{inspect(reason)}"
    end
  end

  defp write_changed!(entries) do
    staged =
      Enum.map(entries, fn %{path: path, data: data} ->
        temp = path <> ".tmp-#{System.unique_integer([:positive])}"
        {temp, path, Jason.encode!(data, pretty: true) <> "\n"}
      end)

    try do
      Enum.each(staged, fn {temp, _path, content} -> File.write!(temp, content) end)

      Enum.reduce(staged, [], fn {temp, path, _content}, written ->
        case File.rename(temp, path) do
          :ok ->
            [path | written]

          {:error, reason} ->
            raise ArgumentError,
                  "#{path}: fixture rename failed (#{inspect(reason)}); already updated: #{inspect(Enum.reverse(written))}"
        end
      end)
      |> Enum.reverse()
    after
      Enum.each(staged, fn {temp, _path, _content} -> File.rm(temp) end)
    end
  end
end
