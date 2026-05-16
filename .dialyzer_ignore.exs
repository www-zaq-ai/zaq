[
  # Ecto.Multi loses MapSet opaqueness as it passes through helper clauses — known false positive.
  {"lib/zaq/ingestion/rename_service.ex", :call_without_opaque},

  # Executor has defensive if is_integer/is_number guards for runtime values that Dialyzer
  # infers as always-true from static types — same pattern as answering.ex.
  # Reported at module line 1 because clause analysis is module-scoped.
  {"lib/zaq/agent/executor.ex", :pattern_match, 1},

  # Third-party dependency — unmatched returns in jido_ai that we cannot fix.
  {"deps/jido_ai/lib/jido_ai/agent.ex", :unmatched_return}
]
