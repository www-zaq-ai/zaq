# Nested Action traces — post-review coverage

Tracking: `zaq-1dq.16`, per-file slices `zaq-1dq.16.1` and `zaq-1dq.16.2`.

## Current coverage — Run Agent failure follow-up

After the reviewed `zaq-1dq.18` repair (`2f9f73426`), renewed human UX approval,
and expanded three-engine browser verification (`7e551d3c2`), a new
`mix coveralls.json` completed successfully within 600,000 ms:

- **11,900 passed**: 48 doctests, 323 properties, 11,529 tests; 1 skipped,
  164 excluded under the normal suite policy.
- **97.2% overall coverage**. This is a fresh full-suite result, not the earlier
  same-source coverage union documented below.
- Subsequent `mix coverup` succeeded with **no changed production files below 95%**.
  No additional planner/worker slices or metric-only tests were required.

| Follow-up production file | Fresh observed hits | Coverage |
| --- | ---: | ---: |
| `lib/zaq/agent/tools/workflow/run_agent.ex` | 98/100 | 98.00% |
| `lib/zaq/engine/workflows.ex` | 403/420 | 95.95% |
| `lib/zaq/engine/workflows/action.ex` | 65/65 | 100.00% |
| `lib/zaq/engine/workflows/step_runner.ex` | 119/122 | 97.54% |
| `lib/zaq_web/live/bo/ai/workflow_run_live.ex` | 370/387 | 95.61% |
| `lib/zaq/agent/tools/action_contract.ex` | 108/109 | 99.08% |

Report source matches the current production files apart from the exporter's
omitted final newline. The current full report is `cover/excoveralls.json`; a
preserved copy is named `nested-traces-post-feedback-full-coverage.json` in the
approved session temporary directory. No production source changed after this
measurement. The run emitted one SQL Sandbox owner-exit diagnostic despite
passing; this result is not a claim of a log-clean run or an established root cause.

Issue-level verification also passed **216 focused checks** (6 properties,
210 tests), `mix q`/commit-hook `qf`, and **3 expanded browser journeys** across
Chromium, Firefox and WebKit. The user-selected dependency now points to the
`jfayad/jido_ai` fork at the same verified `4cb999e1` revision; user-owned Mix and
workflow JSON changes remain outside these feature commits. Neither a portable
release nor final human landing approval is implied. Final `mix precommit` must
still pass after these report updates.

The remaining sections retain the earlier coverage round as historical evidence.

## Earlier fresh baseline

After the branch review, `mix coveralls.json` completed successfully within its
600,000 ms timeout: **11,883 passed** (48 doctests, 322 properties, 11,513 tests),
1 skipped, 164 excluded; **97.2% overall coverage**. This includes the repository's
ordinary exclusions, not the explicitly enabled real-browser journeys.

Only after that success, `mix coverup` identified two changed production files
below 95%: `ActionContract` and `Workflows`. No older report was substituted.

## Earlier focused additions and review

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

## Earlier targeted measurement

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
