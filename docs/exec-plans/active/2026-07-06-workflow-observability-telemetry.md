# Execution Plan

---

## Plan: Workflow observability — a uniform `:telemetry` event stream for every run, step, and pruned branch

**Date:** 2026-07-06
**Author:** Jad (drafted by agent)
**Status:** `active`
**Related debt:** n/a
**PR(s):**

> This is **Part A** of the workflow-observability investigation. **Part B**
> (the `"incomplete"` run status that stops a silently-pruned terminal branch
> from masquerading as `"completed"`) is **done** — see
> `WorkflowRunAgent.finalize/2` and `memory: project_workflow_incomplete_status`.

---

## Goal

A workflow run executes synchronously inside a **single bare Task** (spawned by
`TriggerNode` via `Task.Supervisor.async_stream_nolink`, or by
`EventRegistry.fire_or_register`). Today the engine emits **zero `:telemetry`**
— visibility is a scatter of `Logger` lines at run boundaries plus per-step
`Logger.info` inside `StepRunner`, and pruned branches are near-silent. There is
no single stream a consumer can subscribe to in order to "listen to all events,
success or failure" — the exact ask that opened this investigation.

Done looks like: every run, every step (including each map fork), and every
pruned edge emits a native `:telemetry` event with a documented
measurements/metadata contract. Any consumer — a default structured logger, the
existing `Zaq.Engine.Telemetry.Collector` (persistence → dashboards), or the BO
run view (live step-by-step progress) — attaches once and sees the whole
lifecycle. "Stopped with no reason, no logs" becomes impossible: a pruned
terminal branch emits `[:zaq, :workflow, :edge, :pruned]` **and** the run emits
`[:zaq, :workflow, :run, :stop]` with `status: "incomplete"` and the unreached
leaves.

---

## Context

- [x] `docs/services/workflows.md` — execution flow, finalize, lifecycle events
- [x] `docs/services/telemetry.md` — `Zaq.Engine.Telemetry` (record/4, Buffer,
      Collector, Points→Rollups→dashboard), the existing persistence path
- [x] Existing code reviewed:
  - `lib/zaq/engine/workflows/step_runner.ex` — `execute_step/8` is the single
    choke point for every real step call (map forks included): `t0`,
    `create_step_run "running"`, `call_with_strategy`, then a `case` over
    `{:ok,…}` / `{:error, :timeout}` / `{:error, {:waiting_for_human,…}}` /
    `{:error, reason}`, plus a `rescue` (re-raises) and `rescue ConditionNotMet`
    (skip). Already `Logger.info`s completed/failed; `step started` is `debug`.
  - `lib/zaq/engine/workflows/workflow_run_agent.ex` — `execute/2` transitions
    to `running` + dispatches `run.started`; `finalize/2` decides
    `waiting|failed|incomplete|completed` and dispatches the matching lifecycle
    event. Natural run start/stop emission points.
  - `lib/zaq/engine/workflows/steps/edge_step.ex` — `maybe_check_condition/5`
    false branch: `write_skip_trace` + `raise ConditionNotMet`. The prune
    origin — where an `edge.pruned` event belongs.
  - `lib/zaq/engine/workflows/run_watcher.ex` — `handle_driver_down/2` is the
    only place that observes a **hard** driver crash (Runic-level exception /
    kill). The run `exception` emission point.
  - `lib/zaq/engine/telemetry/collector.ex` — GenServer that
    `:telemetry.attach_many`s `@events` at startup and persists Points (gated by
    `capture_infra_metrics`, with noise filters). The extension point for
    optional persistence.
  - `lib/zaq/engine/telemetry.ex` — `record/4` → `Buffer.enqueue` → Points, with
    an allowlist filter (`qa.*`, `feedback.*`, `ingestion.*`).

### Infrastructure Audit

- [x] Native `:telemetry` is the established pattern: `[:zaq, :node_router,
      :async, :failed]`, `[:zaq, :chat_bridge, :message, :processed|:failed]`,
      `[:zaq, :repo, :query]`. New events follow the `[:zaq, :workflow, …]`
      namespace — **no new dependency**.
- [x] `Collector.attach_many` is the idiomatic persistence hook; adding workflow
      events to its `@events` list routes them to Points→Rollups→BO dashboards
      **without** a parallel path.
- [x] Run-level PubSub already exists (`broadcast_run_update` via the
      `run.*` NodeRouter events) — telemetry is **additive** for step-level
      granularity, not a replacement for run-level BO refresh.
- [x] `StepRunner` already `Logger.info`s completed/failed — Step 5 centralizes
      logging in the handler and removes the inline duplicates (no double logs).

---

## Event taxonomy (the contract)

All events live under `[:zaq, :workflow, …]`. Measurements are numeric; metadata
is descriptive. Emitted by a single module `Zaq.Engine.Workflows.Telemetry`
(Step 1) so the shape has one home.

| Event | Measurements | Metadata |
|---|---|---|
| `[:zaq, :workflow, :run, :start]` | `system_time` | `run_id, workflow_id, trigger_type` |
| `[:zaq, :workflow, :run, :stop]` | `duration_ms, step_count` | `run_id, workflow_id, status` (`completed`\|`incomplete`\|`failed`\|`waiting`\|`paused`), `unreached_leaves, failed_steps` |
| `[:zaq, :workflow, :run, :exception]` | `duration_ms` | `run_id, workflow_id, reason` (from `RunWatcher`, hard death) |
| `[:zaq, :workflow, :step, :start]` | `system_time` | `run_id, step_name, step_index, module, map_index` |
| `[:zaq, :workflow, :step, :stop]` | `duration_ms` | `run_id, step_name, step_index, status` (`completed`\|`failed`\|`failed_fatal`\|`waiting`\|`skipped`\|`timeout`), `reason, map_index` |
| `[:zaq, :workflow, :step, :exception]` | `duration_ms` | `run_id, step_name, step_index, kind, reason, stacktrace` (the `rescue` that re-raises) |
| `[:zaq, :workflow, :edge, :pruned]` | — | `run_id, edge_name, field, op, actual, expected` |

**Status is authoritative on the emitting side** — StepRunner already classifies
each branch, so `:step, :stop` carries the real status rather than being inferred
by a consumer.

---

## Steps

Each step is an independent TDD unit (red → green). Target ≥95% coverage on new
code (`docs/testing-approach.md`). One `docs/exec-plans/active` checkbox per step.

### Step 1 — `Zaq.Engine.Workflows.Telemetry` (emission API + taxonomy)
- New module wrapping `:telemetry.execute/3` with typed helpers: `run_start/1`,
  `run_stop/2`, `run_exception/2`, `step_start/1`, `step_stop/2`,
  `step_exception/2`, `edge_pruned/1`. `@moduledoc` documents the table above.
- **Tests:** `:telemetry.attach` a test handler; assert each helper emits the
  right event name, measurements, and metadata keys. Pure, no DB.

### Step 2 — Instrument `StepRunner.execute_step/8`
- `step_start` after `create_step_run`; `step_stop` in **every** terminal branch
  carrying its status; `step_exception` in the re-raising `rescue`; `step_stop`
  with `status: "skipped"` in the `ConditionNotMet` rescue and the resume-cache
  short-circuits in `run_step/8`.
- **Tests:** attach a handler, drive a workflow through OkAction / ErrorAction /
  a timeout / WaitingAction / a resumed run; assert one `:step, :start` and one
  `:step, :stop` per step with the correct `status`. Verify a map/`Batch` node
  emits one pair **per fork** with distinct `map_index`.

### Step 3 — Instrument `EdgeStep` prunes
- Emit `edge.pruned` in `maybe_check_condition/5`'s false branch (alongside the
  existing `write_skip_trace`), carrying `field/op/actual/expected`.
- **Tests:** a pruned `a→b` workflow (reuse the Part-B fixtures) emits exactly
  one `edge.pruned` with the condition metadata; a passing edge emits none.

### Step 4 — Instrument `WorkflowRunAgent` + `RunWatcher`
- `run_start` at the `running` transition; `run_stop` in each `finalize/2` branch
  (all of `completed|incomplete|failed|waiting`), reusing the already-computed
  `duration_ms`, `step_count`, `unreached_leaves`, `failed_steps`;
  `run_exception` from `RunWatcher.handle_driver_down/2`.
- **Tests:** one run per terminal status asserts a single `:run, :stop` with the
  matching `status` (incl. `incomplete` from Part B) and populated measurements.

### Step 5 — Default structured-logging handler (turns events into logs)
- `Zaq.Engine.Workflows.TelemetryLogger`: `attach_many` at engine-supervisor
  startup; renders every `[:zaq, :workflow, …]` event as a structured `Logger`
  line at a configurable level (`step.start`/`edge.pruned` at `:debug`,
  `stop`/`exception` at `:info`/`:warning`). **Remove** the now-duplicated inline
  `Logger.info`/`error` step lines from `StepRunner` so logging has one home.
- **Tests:** with the handler attached, `capture_log` asserts a line per event;
  assert StepRunner no longer double-logs. Guard the map-fork firehose: per-fork
  lines stay `:debug` (or sampled) so a 10k-item batch can't flood logs.

### Step 6 — (Phase 2, optional) Persist metrics for BO dashboards
- Extend `Collector.@events`/`handle_event` to map `:step, :stop` and `:run,
  :stop` to Points (`workflow.step.duration_ms`, `workflow.run.duration_ms`,
  status counts) with `workflow_id`/`status` dimensions → Rollups → a
  "Workflows" dashboard tile (failure rate, avg step duration, incomplete
  rate). Gated like other infra metrics. **Deferrable** — Steps 1–5 already
  satisfy "listen to all events."

### Step 7 — Docs + quality gate
- Add the taxonomy table to `docs/services/workflows.md` and
  `docs/services/telemetry.md`; update the lifecycle-events section. Run
  `mix format` + `mix q`; confirm coverage on new modules.

---

## Risks & decisions

- **Map fan-out cardinality.** A `map`/`Batch` node emits one step pair per fork,
  up to the `map_max_items` cap (10k). Telemetry `execute` is cheap, but the
  **logging** handler and any **persistence** must keep per-fork at `:debug` /
  aggregate — never one info-log or one Point per item. Called out in Steps 5–6.
- **No double logging.** Step 5 removes the inline StepRunner `Logger` calls in
  the same change that adds the handler, so we never ship both.
- **Consumer failure isolation.** Handlers must never raise — a raising
  `:telemetry` handler is detached globally by the library. The default handler
  wraps its body defensively; documented for future consumers.
- **Ordering / sequential today.** Execution is sequential (`react_until_satisfied`
  is not run `async`), so step events arrive in index order. If map async is ever
  enabled (`docs/services/workflows.md` notes it is intentionally off), per-fork
  events interleave — consumers must key on `run_id`+`step_name`+`map_index`, not
  arrival order. Documented in the taxonomy.
- **Cost of `:telemetry` when nothing is attached** is a no-op — safe to emit
  unconditionally; persistence stays gated by `capture_infra_metrics`.

---

## Acceptance

- [ ] Every run/step/pruned-edge emits its event per the taxonomy (Steps 1–4).
- [ ] A single `:telemetry.attach_many` on `[:zaq, :workflow, …]` observes a full
      run's lifecycle end-to-end in a test.
- [ ] The Part-B silent case now produces: `edge.pruned` + `run.stop{status:
      "incomplete", unreached_leaves: [...]}` — the "stopped with no reason"
      symptom is fully traceable from the event stream alone.
- [ ] No duplicate step logs; map-fork logging cannot flood.
- [ ] `mix q` clean; ≥95% coverage on new modules; docs updated.

---

## Rollout

Ship Steps 1–5 as one PR (the observability stream + default logger — the whole
of the user's ask). Step 6 (dashboards) as a follow-up PR. No migration; no
runtime behavior change beyond additive events and consolidated logging.
