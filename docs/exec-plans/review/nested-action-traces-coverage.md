# Nested Action traces — post-review coverage

Tracking: `zaq-1dq.16`, per-file slices `zaq-1dq.16.1` and `zaq-1dq.16.2`.

## Fresh baseline

After the branch review, `mix coveralls.json` completed successfully within its
600,000 ms timeout: **11,883 passed** (48 doctests, 322 properties, 11,513 tests),
1 skipped, 164 excluded; **97.2% overall coverage**. This includes the repository's
ordinary exclusions, not the explicitly enabled real-browser journeys.

Only after that success, `mix coverup` identified two changed production files
below 95%: `ActionContract` and `Workflows`. No older report was substituted.

## Focused additions and review

Separate source-only worktrees were used for the two read-only planning tasks and
their scoped test workers. Complete per-file plans were passed to the workers;
their allowed test files do not overlap. The parent reviewed and integrated the
diffs and ran validation serially in the established dependency/database environment.
No development server or parallel build environment was needed in those worktrees.

Added tests only in:

- `test/zaq/agent/tools/action_contract_trace_test.exs`: malformed ancestry,
  missing observer destinations, bounded evidence without changing original
  results, typed ToolResult/Record/ContentPart handling across observer routes,
  and real Jido envelope classification.
- `test/zaq/engine/workflows/step_trace_events_test.exs`: wrong-run rollback,
  malformed event metadata, and unsupported typed/runtime evidence sanitization
  with real persisted and broadcast snapshots.

Review corrected new-fixture mistakes before accepting the additions: supported
Record fields and tagged result envelopes; event identity reuse and nested `data`
shape; pinned broadcast patterns rather than unsupported assertion guards; valid
map-shaped Jido output; and struct-updated malformed events rather than invalid
inputs to the Runtime.Event constructor. Existing scenarios/assertions and all
production APIs remain unchanged. Action reuse is not applicable: no operation or
tool was introduced. No test-only production hook or private function exposure
was added. This follow-up self-review approves the coverage additions.

## Targeted measurement

Commands passed:

```sh
mix test test/zaq/agent/tools/action_contract_trace_test.exs test/zaq/engine/workflows/step_trace_events_test.exs
mix q
mix test test/zaq/agent/tools/action_contract_trace_test.exs test/zaq/engine/workflows/step_trace_events_test.exs --cover --export-coverage nested-trace-followup
```

Both targeted runs passed **22 checks** (2 properties, 20 tests). The coverage run
exported `cover/nested-trace-followup.coverdata`. It intentionally ran only the
two edited test files, not the whole suite again; its project-wide total is 1.5%
and is **not** a final whole-project coverage percentage.

For the same unchanged production source, unioning observed covered lines from
the fresh full-suite JSON baseline with the targeted export gives:

| File | Fresh full-suite hits | Target-only hits | Additional covered lines | Observed union |
| --- | ---: | ---: | ---: | ---: |
| `lib/zaq/agent/tools/action_contract.ex` | 98/109 (89.91%) | 96/109 (88.07%) | 10 | **108/109 (99.08%)** |
| `lib/zaq/engine/workflows.ex` | 395/416 (94.95%) | 79/416 (18.99%) | 4 | **399/416 (95.91%)** |

The baseline JSON source and current files match except for the exporter's omitted
final newline, so line identities are unchanged. Counts were derived from the
preserved baseline JSON and `:cover.analyse(module, :calls, :line)` on the targeted
export; neither the baseline report nor production code was rewritten to improve
the numbers. This is a same-source evidence union, not a claim that another final
full-suite coverage command ran.

`ActionContract`'s remaining uncovered line is the defensive unknown-envelope
fallback at line 180. The exercised unsupported return is normalized to an error
by real Jido before that fallback; no helper/mock was invented to force it.
The other 17 missed `Workflows` lines are unrelated existing branches; they were
not expanded solely for metrics. Both affected files exceed the 95% target on
the observed union, and all newly missed workflow trace branches are exercised.

## Remaining gates

Final `mix precommit` and final human landing approval remain separate. Feature
browser E2E already passed in Chromium, Firefox and WebKit, and no UI/production
change occurred during this coverage phase. The explicit `zaq-vhs` deferral and
the local-Jido/portable-release distinction remain in force.
