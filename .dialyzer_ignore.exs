[
  # Mix is not in the dialyzer PLT — Mix task files produce only false positives
  {"lib/mix/tasks/zaq.fetch_python.ex", :callback_info_missing},
  {"lib/mix/tasks/zaq.fetch_python.ex", :unknown_function},
  {"lib/mix/tasks/zaq.fetch_python.ex", :pattern_match_cov},

  # Ecto.Multi passes through helper clauses that lose MapSet opaqueness — known false positive
  # Narrowed to the exact Multi.update/3 call site (line 185, col 18)
  {"lib/zaq/ingestion/rename_service.ex", :call_without_opaque, {185, 18}},

  # parse_html/1 intentionally raises (unimplemented stub); no_return is expected
  {"lib/zaq/ingestion/document_chunker.ex", :no_return, {799, 8}},

  # maybe_add_logprobs/2 and maybe_confidence_score/2 have intentional `false` defensive
  # clauses for when supports_logprobs?() returns false from app config at runtime.
  # Dialyzer cannot see runtime config values so it infers the default `true` only.
  # Dialyzer reports this at module line 1 (clause analysis is module-scoped).
  {"lib/zaq/agent/answering.ex", :pattern_match, 1},

  # cfg.dimension is typed integer() by parse_int/2 so the `|| "not set"` nil-guard
  # can never match; the defensive fallback is intentional for display safety.
  {"lib/zaq_web/live/bo/ai/ai_diagnostics_live.ex", :guard_fail, 113}
]
