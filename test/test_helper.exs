# :paradedb tests need a ParadeDB-enabled Postgres; the test-paradedb CI job
# re-includes them via `mix test --include paradedb`.
#
# :benchmark_liverag runs the LiveRAG RAG benchmark against REAL AI credentials
# (real embedding + LLM calls). Excluded by default; run explicitly with
# `mix test --only benchmark_liverag`. Skips itself unless BENCH_LIVERAG_* env
# vars are set, so it never runs/charges in normal CI.
ExUnit.start(exclude: [:integration, :paradedb, :benchmark_liverag], capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Zaq.Repo, :manual)
Logger.put_module_level(Postgrex.Protocol, :none)
Logger.put_module_level(Task.Supervised, :none)
