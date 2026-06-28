defmodule Zaq.TestSupport.LiveRAGCorpus do
  @moduledoc """
  Manages the LiveRAG document corpus in the test DB so it's **ingested once per
  embedding model** instead of every run.

  Embedding 970 docs is the slow/expensive part of the benchmark. This keeps the
  corpus committed in the test DB and a per-model `pg_dump` under
  `priv/bench/liverag/corpus/`, keyed by `model@dimension`. Resolution order:

    1. **reuse**   — the committed corpus already matches the model → do nothing
    2. **restore** — a dump exists for the model → `psql` it back (fast)
    3. **build**   — neither → run `build_fun` (ingest all docs) + dump it

  Restore is best-effort: any failure falls back to a full rebuild, so the
  benchmark can never be blocked by a bad dump. Switching embedding models picks
  a different dump (or builds a new one), leaving the old dump intact.
  """
  require Logger

  alias Zaq.Ingestion.Chunk
  alias Zaq.Repo

  @dump_tables ~w(documents chunks)

  @doc "Corpus directory (created on demand), gitignored."
  def dir do
    path = Path.join([File.cwd!(), "priv", "bench", "liverag", "corpus"])
    File.mkdir_p!(path)
    path
  end

  @doc ~s|Filename-safe signature for an embedding model + dimension.|
  def signature(model, dimension) do
    safe = String.replace(model, ~r/[^A-Za-z0-9._-]/, "_")
    "#{safe}@#{dimension}"
  end

  @doc """
  Ensures the committed test DB holds the corpus for `{model, dimension}`.

  `build_fun` must ingest the full corpus (reset table + embed all docs) when
  called. Returns `:reused | :restored | :built`.
  """
  def ensure_loaded!(model, dimension, build_fun) when is_function(build_fun, 0) do
    sig = signature(model, dimension)

    cond do
      current_signature() == sig and chunks_present?() ->
        Logger.info("[liverag] corpus reused (#{sig})")
        :reused

      File.exists?(dump_path(sig)) and try_restore(sig, dimension) ->
        mark_loaded(sig)
        Logger.info("[liverag] corpus restored from dump (#{sig})")
        :restored

      true ->
        Logger.info("[liverag] building corpus (#{sig}) — this is the slow path")
        build_fun.()
        dump(sig)
        mark_loaded(sig)
        :built
    end
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp dump_path(sig), do: Path.join(dir(), "#{sig}.sql")
  defp marker_path, do: Path.join(dir(), "CURRENT")

  defp current_signature do
    case File.read(marker_path()) do
      {:ok, sig} -> String.trim(sig)
      _ -> nil
    end
  end

  defp mark_loaded(sig), do: File.write!(marker_path(), sig)

  defp chunks_present? do
    Chunk.table_exists?() and Repo.aggregate(Chunk, :count) > 0
  rescue
    _ -> false
  end

  # Data-only dump of the two corpus tables (avoids dropping tables that other
  # FKs depend on). Generated columns (content_tsv) are excluded by pg_dump.
  defp dump(sig) do
    args =
      conn_args() ++
        ["--data-only", "--no-owner"] ++
        Enum.flat_map(@dump_tables, &["-t", &1]) ++
        ["-f", dump_path(sig)]

    case System.cmd("pg_dump", args, env: pg_env(), stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> Logger.warning("[liverag] pg_dump failed (#{code}); dump skipped: #{out}")
    end
  end

  defp try_restore(sig, dimension) do
    # Fresh empty schema at the right dimension, then COPY the dumped rows back.
    Chunk.reset_table(dimension)
    Repo.query!("TRUNCATE documents CASCADE")

    args = conn_args() ++ ["-v", "ON_ERROR_STOP=1", "-f", dump_path(sig)]

    case System.cmd("psql", args, env: pg_env(), stderr_to_stdout: true) do
      {_out, 0} ->
        chunks_present?()

      {out, code} ->
        Logger.warning("[liverag] psql restore failed (#{code}); rebuilding: #{out}")
        false
    end
  rescue
    e ->
      Logger.warning("[liverag] restore raised (#{Exception.message(e)}); rebuilding")
      false
  end

  defp conn_args do
    c = Repo.config()

    [
      "-h",
      to_string(Keyword.get(c, :hostname, "localhost")),
      "-p",
      to_string(Keyword.get(c, :port, 5432)),
      "-U",
      to_string(Keyword.fetch!(c, :username)),
      "-d",
      to_string(Keyword.fetch!(c, :database))
    ]
  end

  defp pg_env, do: [{"PGPASSWORD", to_string(Keyword.get(Repo.config(), :password, ""))}]
end
