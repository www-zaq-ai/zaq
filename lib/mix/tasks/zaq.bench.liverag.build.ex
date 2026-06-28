defmodule Mix.Tasks.Zaq.Bench.Liverag.Build do
  @shortdoc "Download + normalize the LiveRAG benchmark into JSONL"

  @moduledoc """
  Builds the local LiveRAG benchmark data for ZAQ's RAG harness.

  Downloads the upstream Parquet (once), then writes two files next to it under
  `priv/bench/liverag/`:

    * `questions.jsonl` — 895 questions (question, answer, supporting_doc_ids,
      claims, session, acs, irt_diff)
    * `docs.jsonl`      — the ~970 unique source documents (`doc_id`, `content`)

  Both outputs are gitignored derived data — regenerate any time with:

      mix zaq.bench.liverag.build

  Dev-only: depends on `:explorer` (Parquet reader), which is scoped to `:dev`.
  Source: https://huggingface.co/datasets/LiveRAG/Benchmark (arXiv 2511.14531).
  """

  use Mix.Task

  alias Explorer.DataFrame

  @dir Path.join([File.cwd!(), "priv", "bench", "liverag"])
  @parquet_name "LiveRAG_banchmark_20250910.parquet"
  @url "https://huggingface.co/datasets/LiveRAG/Benchmark/resolve/main/#{@parquet_name}"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:req)
    File.mkdir_p!(@dir)

    parquet = Path.join(@dir, @parquet_name)
    ensure_parquet(parquet)

    rows = parquet |> DataFrame.from_parquet!() |> DataFrame.to_rows()
    {questions, docs} = normalize(rows)

    write_jsonl(Path.join(@dir, "questions.jsonl"), questions)
    write_jsonl(Path.join(@dir, "docs.jsonl"), Map.values(docs))

    Mix.shell().info("questions: #{length(questions)}  unique docs: #{map_size(docs)}")
  end

  defp ensure_parquet(path) do
    if File.exists?(path) do
      :ok
    else
      Mix.shell().info("downloading #{@url}")
      %{status: 200, body: body} = Req.get!(@url, receive_timeout: 180_000)
      File.write!(path, body)
    end
  end

  # Folds the raw rows into the question list (in order) and a doc_id => doc map.
  defp normalize(rows) do
    {questions, docs} =
      Enum.reduce(rows, {[], %{}}, fn row, {qs, docs} ->
        {ids, docs} = collect_docs(row["Supporting_Documents"], docs)
        claims = row["Answer_Claims"] || %{}

        question = %{
          index: trunc(row["Index"]),
          question: row["Question"],
          answer: row["Answer"],
          supporting_doc_ids: ids,
          claims: %{
            direct: claims["direct"] || [],
            useful: claims["useful"] || [],
            useless: claims["useless"] || []
          },
          session: row["Session"],
          acs: row["ACS [-2 : 1]"],
          irt_diff: row["IRT-diff [-6 : 6]"]
        }

        {[question | qs], docs}
      end)

    {Enum.reverse(questions), docs}
  end

  defp collect_docs(supporting_docs, docs) do
    Enum.reduce(supporting_docs, {[], docs}, fn doc, {ids, docs} ->
      id = doc_id(doc)
      docs = Map.put_new(docs, id, %{doc_id: id, content: doc["content"]})
      {ids ++ [id], docs}
    end)
  end

  defp doc_id(%{"doc_id" => id}) when is_binary(id) and id != "", do: id

  defp doc_id(%{"content" => content}) do
    "sha1:" <> (:crypto.hash(:sha, content) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  defp write_jsonl(path, items) do
    File.open!(path, [:write, :utf8], fn file ->
      Enum.each(items, fn item -> IO.write(file, [Jason.encode!(item), "\n"]) end)
    end)
  end
end
