defmodule Zaq.Bench.LiveRAGTest do
  @moduledoc """
  End-to-end LiveRAG RAG benchmark against ZAQ's **real** pipeline + real AI
  credentials (provisioned via the ZAQ Router — see `Zaq.TestSupport.LiveRAGBench`).

  The full 970-doc corpus is **ingested once per embedding model** and kept as a
  committed corpus + per-model dump (`Zaq.TestSupport.LiveRAGCorpus`); later runs
  reuse/restore it instead of re-embedding. Each run asks questions through the
  real `Zaq.Agent.Pipeline.run/2` path (admin scope) against that **full** corpus,
  scoring retrieval recall + answer claim-coverage (LLM judge).

  Excluded by default. Run with:

      BENCH_LIVERAG_ROUTER_KEY=sk-... mix test --only benchmark_liverag

  Env:
    * `BENCH_LIVERAG_ROUTER_KEY` — required (LiteLLM gateway key)
    * `BENCH_LIVERAG_ROUTER_URL` — gateway base URL (default localhost:4020)
    * `BENCH_LIVERAG_LLM_MODEL`  — chat model override (query-rewrite/answer/judge)
    * `BENCH_LIVERAG_LIMIT`      — cap the number of QUESTIONS asked (corpus stays
      full, so retrieval is a real haystack). Omit to ask all 895.

  The first run for a model ingests all 970 docs (slow, one-time); subsequent runs
  are fast. Build the dataset first: `mix zaq.bench.liverag.build`.
  """
  use ExUnit.Case, async: false

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Agent.{Answering, Pipeline}
  alias Zaq.Embedding.Client, as: EmbeddingClient
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Ingestion.{Chunk, DocumentProcessor}
  alias Zaq.Repo
  alias Zaq.TestSupport.{LiveRAGBench, LiveRAGCorpus}

  @moduletag :benchmark_liverag
  @moduletag timeout: :infinity

  setup do
    case prepare() do
      {:skip, reason} -> {:ok, skip: reason}
      {:ok, ctx} -> {:ok, Map.put(ctx, :skip, nil)}
    end
  end

  # Two-phase setup:
  #   1. Committed phase (real connection): provision AI config + ensure the full
  #      corpus is loaded once per embedding model (reuse / restore / build).
  #   2. Question phase (transactional shared): read-only over the committed
  #      corpus; shared mode lets the pipeline's spawned processes see the data.
  defp prepare do
    case LiveRAGBench.questions() do
      {:error, :missing} ->
        {:skip, "data not built — run `mix zaq.bench.liverag.build` first"}

      {:ok, _questions} ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        result = provision_and_load_corpus()
        Sandbox.checkin(Repo)

        case result do
          {:skip, reason} ->
            {:skip, reason}

          {:ok, ctx} ->
            :ok = Sandbox.checkout(Repo, ownership_timeout: :infinity)
            Sandbox.mode(Repo, {:shared, self()})
            {:ok, ctx}
        end
    end
  end

  defp provision_and_load_corpus do
    case LiveRAGBench.setup_real_ai!() do
      {:skip, reason} ->
        {:skip, reason}

      {:ok, ctx} ->
        preflight!()

        status =
          LiveRAGCorpus.ensure_loaded!(ctx.model, ctx.dimension, fn -> build_corpus(ctx) end)

        {:ok, Map.put(ctx, :corpus, status)}
    end
  end

  # Slow path: ingest the FULL corpus once (committed) so it can be dumped/reused.
  defp build_corpus(%{dimension: dimension}) do
    {:ok, docs} = LiveRAGBench.docs()
    Chunk.reset_table(dimension)
    total = length(docs)

    docs
    |> Enum.with_index(1)
    |> Enum.each(fn {%{"doc_id" => id, "content" => content}, i} ->
      {:ok, doc} = DocumentProcessor.store_document(content, LiveRAGBench.doc_source(id))

      case DocumentProcessor.process_and_store_chunks(content, doc.id) do
        {:ok, _report} -> :ok
        {:error, reason} -> raise "Failed to load doc #{id}: #{reason}"
      end

      if rem(i, 10) == 0 or i == total, do: progress("\rbuilding corpus #{i}/#{total}")
    end)

    progress("\n")
  end

  test "runs the LiveRAG benchmark end-to-end", %{skip: skip} = ctx do
    if skip do
      Logger.warning("[liverag] #{skip}")
      :skipped
    else
      run_benchmark(ctx)
    end
  end

  defp run_benchmark(ctx) do
    {:ok, questions} = LiveRAGBench.questions()
    selected = limit_questions(questions, LiveRAGBench.limit())
    total = length(selected)
    chunk_count = Repo.aggregate(Chunk, :count)
    progress("corpus #{ctx.corpus} (#{chunk_count} chunks); asking #{total} questions\n")
    assert chunk_count > 0

    results =
      selected
      |> Enum.with_index(1)
      |> Enum.map(fn {q, i} ->
        progress("\ranswering #{i}/#{total}")
        answer_and_score(q)
      end)

    progress("\n")
    summary = summarize(results)
    stamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")
    write_results(results, summary, stamp)
    write_errors(results, stamp)
    print_report(summary)

    assert summary.count > 0
  end

  # Progress to stderr — visible even though ExUnit runs with capture_log: true.
  defp progress(msg), do: IO.write(:stderr, "[liverag] " <> msg)

  # One real embedding call before building the corpus / asking questions — turns
  # a wrong key/URL into a single clear failure.
  defp preflight! do
    case EmbeddingClient.embed("liverag preflight") do
      {:ok, _vector} ->
        :ok

      {:error, reason} ->
        flunk("""
        ZAQ Router embedding preflight failed: #{inspect(reason)}

        The key reached the gateway but was rejected (or the gateway is wrong).
        Gateway in use: #{LiveRAGBench.router_url()}
        If BENCH_LIVERAG_ROUTER_KEY was issued by a different LiteLLM instance
        (e.g. your local one), set BENCH_LIVERAG_ROUTER_URL to that base URL.
        """)
    end
  end

  defp limit_questions(questions, :all), do: questions
  defp limit_questions(questions, n) when is_integer(n), do: Enum.take(questions, n)

  defp answer_and_score(q) do
    incoming =
      Incoming.new(%{content: q["question"], channel_id: "liverag-bench", provider: :benchmark})

    outgoing = Pipeline.run(incoming, skip_permissions: true)
    answer = outgoing.body
    sources = outgoing.metadata[:sources] || []

    retrieved_ids =
      sources |> Enum.map(&LiveRAGBench.source_to_doc_id/1) |> Enum.reject(&is_nil/1)

    %{
      index: q["index"],
      question: q["question"],
      answer: answer,
      retrieved_doc_ids: retrieved_ids,
      supporting_doc_ids: q["supporting_doc_ids"],
      irt_diff: q["irt_diff"],
      recall: LiveRAGBench.recall(retrieved_ids, q["supporting_doc_ids"]),
      claim_coverage: LiveRAGBench.judge_claim_coverage(q["question"], answer, q["claims"]),
      no_answer: Answering.no_answer?(answer)
    }
  rescue
    e ->
      Logger.error("[liverag] question #{q["index"]} failed: #{Exception.message(e)}")

      error_result(
        q,
        Exception.message(e),
        inspect(e.__struct__),
        Exception.format(:error, e, __STACKTRACE__)
      )
  catch
    # Task.await re-raises a failed task as a process exit, which `rescue` can't
    # catch — without this, one bad question would abort the whole run.
    :exit, reason ->
      Logger.error("[liverag] question #{q["index"]} exited: #{inspect(reason)}")
      error_result(q, "process exit", "exit", Exception.format_exit(reason))
  end

  defp error_result(q, message, type, trace) do
    %{
      index: q["index"],
      question: q["question"],
      error: message,
      error_type: type,
      stacktrace: trace
    }
  end

  defp summarize(results) do
    scored = Enum.reject(results, &Map.has_key?(&1, :error))

    errored = results -- scored

    %{
      count: length(results),
      errors: length(errored),
      error_types: errored |> Enum.map(&(&1[:error_type] || "unknown")) |> Enum.frequencies(),
      no_answer: Enum.count(results, &(&1[:no_answer] == true)),
      mean_recall: mean(scored, :recall),
      hit_rate: rate(scored, &(is_number(&1[:recall]) and &1[:recall] > 0)),
      mean_claim_coverage: mean(scored, :claim_coverage),
      by_difficulty: by_difficulty(scored)
    }
  end

  defp by_difficulty(scored) do
    scored
    |> Enum.group_by(&difficulty_bucket(&1[:irt_diff]))
    |> Map.new(fn {bucket, rows} ->
      {bucket,
       %{
         n: length(rows),
         recall: mean(rows, :recall),
         claim_coverage: mean(rows, :claim_coverage)
       }}
    end)
  end

  # IRT difficulty: lower = easier. Buckets per the dataset's [-6, 6] range.
  defp difficulty_bucket(irt) when is_number(irt) and irt < -1.0, do: "easy"
  defp difficulty_bucket(irt) when is_number(irt) and irt <= 1.0, do: "medium"
  defp difficulty_bucket(irt) when is_number(irt), do: "hard"
  defp difficulty_bucket(_), do: "unknown"

  defp mean(rows, key) do
    values = rows |> Enum.map(& &1[key]) |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      _ -> Float.round(Enum.sum(values) / length(values), 4)
    end
  end

  defp rate(rows, fun) when rows != [], do: Float.round(Enum.count(rows, fun) / length(rows), 4)
  defp rate(_rows, _fun), do: nil

  # Renders the human-readable results table to stderr.
  defp print_report(summary) do
    pct = fn
      nil -> "  n/a"
      v -> :io_lib.format("~5.1f%", [v * 100]) |> to_string()
    end

    rows =
      ["easy", "medium", "hard", "unknown"]
      |> Enum.map(&{&1, summary.by_difficulty[&1]})
      |> Enum.reject(fn {_b, v} -> is_nil(v) end)
      |> Enum.map(fn {b, v} ->
        "  #{String.pad_trailing(b, 9)}#{pad(pct.(v.recall))}#{pad(pct.(v.claim_coverage))}#{pad("#{v.n}")}"
      end)

    error_lines =
      summary.error_types
      |> Enum.sort_by(fn {_type, n} -> -n end)
      |> Enum.map(fn {type, n} -> "      #{pad("#{n}")}  #{type}" end)

    error_section =
      if summary.errors > 0,
        do:
          "\n  ERRORS (see .errors.txt for full trails)\n" <> Enum.join(error_lines, "\n") <> "\n",
        else: ""

    report = """

    ┌─ LiveRAG Benchmark ─────────────────────────────
      Questions scored : #{summary.count - summary.errors} / #{summary.count}  (errors: #{summary.errors})
      No-answer        : #{summary.no_answer}

      RETRIEVAL
        Hit rate (≥1 supporting doc found) : #{pct.(summary.hit_rate)}
        Mean recall                        : #{pct.(summary.mean_recall)}

      ANSWER
        Mean claim coverage                : #{pct.(summary.mean_claim_coverage)}

      BY DIFFICULTY        recall  claim-cov   n
    #{Enum.join(rows, "\n")}
    #{error_section}└─────────────────────────────────────────────────
    """

    progress(report)
  end

  defp pad(s), do: String.pad_leading(s, 9)

  defp write_results(results, summary, stamp) do
    path = Path.join(results_dir(), "#{stamp}.jsonl")

    File.open!(path, [:write, :utf8], fn file ->
      IO.write(file, Jason.encode!(Map.put(summary, :_summary, true)) <> "\n")
      # Keep the JSONL compact — full stacktraces go to the errors file.
      Enum.each(results, fn r ->
        IO.write(file, [Jason.encode!(Map.delete(r, :stacktrace)), "\n"])
      end)
    end)

    progress("wrote results → #{path}\n")
  end

  # Human-readable error trail: every failed question with full stacktrace.
  defp write_errors(results, stamp) do
    errored = Enum.filter(results, &Map.has_key?(&1, :error))

    if errored != [] do
      path = Path.join(results_dir(), "#{stamp}.errors.txt")
      header = "LiveRAG benchmark — #{length(errored)} errors\n#{stamp}\n"
      File.write!(path, [header | Enum.map(errored, &format_error/1)])
      progress("wrote error trail → #{path}\n")
    end
  end

  defp format_error(r) do
    [
      "\n",
      String.duplicate("=", 78),
      "\nQ##{r.index} (#{r[:error_type]}): ",
      r.question,
      "\n",
      r.error,
      "\n\n",
      r[:stacktrace] || "(no stacktrace)",
      "\n"
    ]
  end

  defp results_dir do
    dir = Path.join(LiveRAGBench.dir(), "results")
    File.mkdir_p!(dir)
    dir
  end
end
