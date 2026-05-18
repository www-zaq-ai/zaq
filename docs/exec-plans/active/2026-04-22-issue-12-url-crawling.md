# Execution Plan

## Plan: Issue 12 - URL Crawling with UI-First Delivery

**Date:** 2026-04-22
**Author:** OpenCode
**Status:** `active`
**Related debt:** `docs/exec-plans/tech-debt-tracker.md` (`Ingestion` nice-to-have: ingestion webhooks for external notification on completion)
**PR(s):** TBD

---

## Goal

Deliver issue `#12` by adding URL-based ingestion backed by `www-zaq-ai/crawler-ingest`, starting with Back Office management screens so product and UX can be reviewed before backend wiring. Done means BO users can configure and operate a URL crawler flow from dedicated management screens, submit URLs for crawl, monitor crawl/run status, inspect crawl output, and retry failed runs, while the backend persists crawl sources and runs, enqueues execution through Oban, stores crawled markdown in a dedicated local namespace with source metadata, triggers local ingestion, and emits a completion event that can later power notifications and webhooks.

---

## Context

Docs reviewed:

- [x] `docs/WORKFLOW_AGENT.md`
- [x] `docs/project.md`
- [x] `docs/architecture.md`
- [x] `docs/conventions.md`
- [x] `docs/phoenix.md`
- [x] `docs/services/ingestion.md`
- [x] `docs/services/channels.md`
- [x] `docs/services/system-config.md`
- [x] `docs/QUALITY_SCORE.md`
- [x] `docs/exec-plans/tech-debt-tracker.md`
- [x] `docs/exec-plans/PLAN_TEMPLATE.md`

Existing code reviewed:

- [x] `lib/zaq_web/router.ex`
- [x] `lib/zaq_web/live/bo/communication/channels_index_live.ex`
- [x] `lib/zaq_web/live/bo/communication/channels_index_live.html.heex`
- [x] `lib/zaq_web/live/bo/communication/channels_live.ex`
- [x] `lib/zaq_web/live/bo/communication/channels_live.html.heex`
- [x] `lib/zaq_web/live/bo/ai/ingestion_live.ex`
- [x] `lib/zaq_web/live/bo/ai/ingestion_live.html.heex`
- [x] `lib/zaq_web/live/bo/ai/ingestion_components.ex`
- [x] `lib/zaq/ingestion/ingestion.ex`
- [x] `lib/zaq/ingestion/ingest_job.ex`
- [x] `lib/zaq/ingestion/job_lifecycle.ex`
- [x] `lib/zaq/ingestion/python/runner.ex`
- [x] `lib/mix/tasks/zaq.fetch_python.ex`

Relevant findings:

- The BO already has a clear navigation model for ingestion providers under `/bo/channels/ingestion/*`, which is the right entry point for a dedicated URL crawling management screen.
- The existing ingestion UI in `AI.IngestionLive` already establishes patterns for job status chips, retry/cancel actions, PubSub-driven refresh, and operator-facing empty/loading/error states.
- `Zaq.Ingestion` already owns async job orchestration, Oban integration, and real-time PubSub updates for file ingestion, but `IngestJob` is file-centric and should not be overloaded with URL-crawl-specific concerns.
- `Zaq.Ingestion.Python.Runner` and `mix zaq.python.fetch` already establish the pattern for shipping and invoking Python helpers from `priv/python/crawler-ingest`, but the crawler scripts are not currently present in this workspace.
- BO cross-service calls must continue to route through `NodeRouter`; UI code should not call DB or worker internals directly.
- Issue `#12` explicitly asks for submitted URL listing, job status visibility, and restart capability at the UI level, plus a completion event usable by future notification/webhook work.

---

## Approach

Implement this feature in four small phases, with the first phase focused only on Back Office management screens and realistic UI states.

The backend should introduce a dedicated crawling subdomain under ingestion rather than extending `IngestJob` directly. A URL crawl is a distinct business object with its own lifecycle, configuration, source metadata, and output set. File ingestion jobs can remain the downstream mechanism for processing generated markdown files after crawling completes.

Recommended domain shape:

- `crawl_sources`: durable definition of a submitted URL and crawl policy
- `crawl_runs`: each execution attempt for a source URL
- optional persisted output records if traceability to generated markdown files is needed beyond filesystem metadata

Recommended BO shape:

- add a new ingestion provider card for `URL Crawling`
- add a dedicated management LiveView for source/run operations
- add a crawl detail LiveView for execution timeline, errors, and generated output
- expose retry from the management UI using the same operator patterns already used in file ingestion

Why this approach:

- keeps file ingestion and URL crawling conceptually separate
- allows a product review of screens before locking backend contracts
- reuses existing BO visual language and LiveView interaction patterns
- preserves `Zaq.Ingestion` as the orchestration boundary while keeping crawl-specific persistence and execution isolated
- makes future webhook/notification work an additive completion-event consumer instead of coupling it into the initial worker design

---

## UI Scope First

Phase 1 should produce these screens before backend implementation is wired:

1. `Ingestion Channels` card update
   - Add `URL Crawling` as a visible ingestion provider entry under `/bo/channels/ingestion`.
   - Surface basic configuration state and CTA to open crawler management.

2. `Crawler Management` screen
   - Route proposal: `/bo/channels/ingestion/url_crawler`
   - Include URL submission form, status filters, source list, latest run status, document count, last run time, and retry action.
   - Include empty, loading, processing, success, and failure states.

3. `Crawl Detail` screen
   - Route proposal: `/bo/channels/ingestion/url_crawler/:id`
   - Show source URL, crawl policy snapshot, run timeline, generated files/documents, metadata summary, and error details.

4. `Crawler Settings` panel or tab
   - Include crawl depth, page/domain limits, output namespace, and future completion action settings.
   - For the first UI PR, controls may be visual-only or backed by mock state if backend persistence is not yet present.

---

## Data Model Proposal

The exact schema names can change during implementation, but the plan assumes the following split.

`Zaq.Ingestion.Crawling.Source`
- canonical URL
- enabled flag
- crawl policy fields such as domain restriction, max depth, max pages, and target namespace
- latest run pointers or derived status fields as needed for BO rendering

`Zaq.Ingestion.Crawling.Run`
- belongs to source
- status lifecycle: `pending | processing | completed | completed_with_errors | failed | cancelled?`
- execution timestamps
- stats: pages discovered, pages crawled, markdown files produced, downstream ingestion jobs created
- error payload / summary
- snapshot of effective crawl policy used for the run

`Zaq.Ingestion.Crawling`
- public context API for BO and workers
- create/update source
- enqueue run
- list sources and runs for BO
- get run detail
- retry run
- subscribe to run updates via PubSub

The worker should pass only IDs in Oban args. Large crawler output and page-level payloads should be persisted or written to files, not embedded in job args.

---

## Execution Flow Proposal

Target backend flow:

1. BO user submits a URL.
2. `Zaq.Ingestion.Crawling` stores or updates the crawl source and creates a new run.
3. Oban worker starts the crawl using `Zaq.Ingestion.Python.Runner` against the fetched `crawler-ingest` scripts.
4. The crawler writes markdown output into a dedicated local namespace.
5. Each generated markdown file is then fed into the existing ingestion pipeline through `Zaq.Ingestion.ingest_file/3` or a batch-oriented wrapper.
6. Run status is updated through a dedicated lifecycle helper and broadcast over PubSub.
7. On terminal completion, emit a crawl completion event with enough metadata for issue `#7` / `#8` consumers.

Recommended metadata attached to generated files/documents:

- `source_url`
- `crawl_source_id`
- `crawl_run_id`
- `crawled_at`
- `domain`
- `page_url`
- `content_hash` if available

---

## Steps

- [ ] Step 1: Add this execution plan under `docs/exec-plans/active/` and keep it updated as design decisions or blockers change.

- [ ] Step 2: Deliver the UI-first PR for issue `#12`.
  - Add a `URL Crawling` provider card in `ChannelsIndexLive`.
  - Add a new BO LiveView for crawler management with realistic mock or adapter-backed state.
  - Add a crawl detail LiveView and route.
  - Reuse existing BO interaction patterns for filters, status badges, retry actions, and empty/error states.
  - Add LiveView tests for page rendering and key operator actions.

- [ ] Step 3: Define the crawling domain model and persistence layer.
  - Add migrations for crawl sources and crawl runs.
  - Add schemas and public context APIs under a dedicated ingestion crawling namespace.
  - Add a dedicated lifecycle helper for crawl-run state transitions and PubSub broadcasts.
  - Add tests for create/list/get/retry semantics and transition rules.

- [ ] Step 4: Wire BO screens to the real crawling context.
  - Replace mock state with context-backed queries and events.
  - Route all BO cross-service calls through `NodeRouter`.
  - Add real submit, filter, detail, and retry flows.
  - Add LiveView integration tests against real persisted crawl source/run data.

- [ ] Step 5: Integrate `crawler-ingest` execution.
  - Confirm how crawler scripts are sourced: vendored in repo, fetched during setup, or both.
  - Add an Elixir wrapper around the crawler entrypoint with a stable contract and error normalization.
  - Ensure the worker writes markdown output into a dedicated namespace under local ingestion storage.
  - Add tests around command invocation, failure mapping, and idempotent retry behavior.

- [ ] Step 6: Connect crawl output to the existing ingestion pipeline.
  - Trigger ingestion of generated markdown files after a successful crawl.
  - Persist and expose downstream ingestion counts or references in the crawl run.
  - Ensure retries do not duplicate work incorrectly.
  - Add integration tests that prove crawled markdown becomes visible to the knowledge base pipeline.

- [ ] Step 7: Emit completion events for future notification/webhook consumers.
  - Define a stable crawl completion event payload.
  - Publish it on successful and partial-success terminal states as appropriate.
  - Document how issue `#7` and `#8` can consume it later.
  - Add tests for event emission and terminal-state coverage.

- [ ] Step 8: Validation and closeout.
  - Run targeted tests for crawling context, workers, and LiveViews.
  - Run full `mix test`.
  - Run `mix precommit`.
  - Update docs in `docs/services/ingestion.md` and any BO routing/UI docs if behavior or navigation changed.

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Deliver issue `#12` UI-first | The issue explicitly calls out operator-facing management needs; UI review can happen before backend contracts are finalized | 2026-04-22 |
| Use a dedicated crawling subdomain instead of extending `IngestJob` | Existing ingestion jobs are file-oriented and do not model URL source, crawl policy, or crawl-run history cleanly | 2026-04-22 |
| Put crawler BO entry under `Channels > Ingestion` | This matches the current BO information architecture for ingestion providers | 2026-04-22 |
| Treat file ingestion as a downstream step of crawl completion | Keeps crawl orchestration distinct from markdown processing and reuses the stable ingestion pipeline | 2026-04-22 |
| Plan for a completion event in the initial domain design | Future notifications/webhooks should consume a stable event rather than requiring later worker refactors | 2026-04-22 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| Need a final decision on how `crawler-ingest` scripts are supplied locally (`priv/`, fetch task, or both) | Maintainer + implementer | Open |
| Need product confirmation on the target namespace/path convention for crawled markdown output | Maintainer / product | Open |
| Need product clarification on retry semantics: rerun full crawl only, or allow re-ingestion-only flows later | Maintainer / product | Open |

---

## Definition of Done

- [ ] UI-first management screens for URL crawling are implemented and reviewed
- [ ] Crawl source and run persistence model is implemented
- [ ] BO submit/list/detail/retry flows use the real crawling context
- [ ] Oban-backed crawl execution invokes `crawler-ingest` successfully
- [ ] Crawled markdown is written into a dedicated local namespace with source metadata
- [ ] Generated markdown is ingested through the existing ingestion pipeline
- [ ] Crawl completion event is emitted for future notification/webhook consumers
- [ ] Tests cover LiveView flows, context rules, and worker execution paths
- [ ] `mix test` passes
- [ ] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`
