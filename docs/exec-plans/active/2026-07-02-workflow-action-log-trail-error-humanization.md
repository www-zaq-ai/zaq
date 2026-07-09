# Execution Plan

---

## Plan: Capture the real cause of workflow run interruptions (not a fixed "node_shutdown" guess)

**Date:** 2026-07-02
**Author:** Jad (drafted by agent)
**Status:** `active`
**Related debt:** n/a
**PR(s):**

---

## Goal

Today, every workflow run/step orphaned by a node restart gets the exact same
hardcoded label — `reason: "node_shutdown", message: "Server restarted during
execution"` — regardless of what actually happened: a deliberate deploy
restart, a `systemctl restart`, an OOM-kill, a host crash, or the process
being killed mid-batch. That label is a guess dressed up as a fact and it is
wrong most of the time it isn't a clean restart. Done looks like: the system
distinguishes a *graceful* stop (we know exactly why — deploy/restart, and we
get to record that in real time before we go down) from a *hard, unplanned*
death (we did not get to run any code, so we honestly say "no clean shutdown
was observed" and attach whatever forensic signal is actually available —
crash dump presence, batch/map context — instead of fabricating a specific
cause we can't know).

---

## Context

- [x] `docs/services/workflows.md`
- [x] `docs/architecture.md` (multi-node roles, on-prem deployment — no k8s assumed)
- [x] Existing code reviewed:
  - `lib/zaq/application.ex` (`prep_stop/1` at :80 — currently a no-op; this
    is the one hook that runs *before* a graceful shutdown, while the app
    still knows why it's stopping)
  - `lib/zaq/engine/workflows.ex` (`interrupt_run/2` at :750 — hardcodes
    `"node_shutdown"`; already accepts an `_opts` param that is silently
    discarded)
  - `lib/zaq/engine/workflows/startup_recovery.ex` (fires on every boot,
    sweeps anything left `"running"`/`"pending"`, no forensic distinction)
  - `lib/zaq/engine/workflows/run_recovery_worker.ex` (per-run Oban job,
    calls `interrupt_run/1` with no options — the wiring point for a real
    reason once one exists)
  - `lib/zaq/engine/workflows/map_node_builder.ex` (batch/map fan-out is
    exactly the kind of step likely to be the actual cause of an OOM-kill —
    `max_items` cap already exists as a guardrail)

### Infrastructure Audit

- [x] Existing entry points checked: `interrupt_run/2`'s `_opts` param is the
      intended extension point and is unused — this plan wires it up rather
      than adding a parallel code path.
- [x] `@moduledoc` read for every module that will receive new code:
      `Zaq.Application` owns process lifecycle (start/stop), `Zaq.Engine.Workflows`
      owns run/step transitions — both are the correct owners for their part
      of this change; no new context needed for the core mechanism.
- [x] No parallel code path being created — this extends `prep_stop/1`,
      `interrupt_run/2`, and `StartupRecovery`, all of which already exist for
      exactly this purpose but are incomplete.
- [x] Provider/credential/URL logic: n/a.

---

## State of the Art (research)

How other systems tell "why did this die" apart from "it's just gone," across
OS/orchestrator, job-queue, and BEAM-specific layers:

**The dead process can never explain itself.** If a process is genuinely
`SIGKILL`'d (OOM-killer, `kill -9`, host power loss), it gets zero CPU time to
write anything down — there is no code path inside the crashed process that
can record "I was OOM-killed." The real signal always lives *outside* the
process, in something that outlives it:
- Linux: `dmesg` / `journalctl -k` OOM-killer log lines, and cgroup v2
  `memory.events`'s `oom`/`oom_kill` counters ([Netdata](https://www.netdata.cloud/academy/diagnosing-linux-cgroups/), [kernel cgroup-v1 docs](https://docs.kernel.org/admin-guide/cgroup-v1/memory.html)).
- Kubernetes: `kubectl describe pod` surfaces `lastState.terminated.reason:
  OOMKilled` + `exitCode: 137` (128+SIGKILL) directly from the kubelet, which
  watched the container die — the app itself never reports this
  ([groundcover](https://www.groundcover.com/kubernetes-troubleshooting/exit-code-137), [Komodor](https://komodor.com/learn/how-to-fix-oomkilled-exit-code-137/)). Exit 143 (128+SIGTERM) means a graceful signal was honored in time; 137 always means an unstoppable kill.
- systemd: the **watchdog** pattern (`sd_notify("WATCHDOG=1")` on a timer) is
  the OS-level version of a heartbeat — the *supervisor* (systemd), not the
  service, decides "it went silent" and kills/restarts it, then logs the
  reason in `journalctl -u <service>` ([freedesktop sd_notify](https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html)).

**Erlang/BEAM specifically:**
- `erl_crash.dump` is written by the *BEAM itself* choosing to halt (VM-level
  allocator failure, `erlang:halt/1,2`, a kernel-supervisor failure, or
  `SIGUSR1` forcing a dump) — it captures a real slogan/reason
  ([erlang.org crash_dump docs](https://www.erlang.org/doc/apps/erts/crash_dump.html)). Critically, an **external** `SIGKILL` (OOM-killer, `kill -9`) does **not** produce a crash dump — the OS gives the BEAM no chance to write one. So: crash dump present → genuine BEAM-internal fatal error with a real reason string to surface; crash dump absent + no clean-stop marker → externally killed, and the *actual* cause (OOM vs host reboot vs manual `kill -9`) can only be confirmed by correlating OS/journal logs at the same timestamp, not from inside the app.
- `heart(1)` is Erlang's built-in watchdog companion process — it monitors the
  VM and restarts it if it stops responding, mirroring the systemd watchdog
  pattern at the BEAM level ([10 Ways to Stop an Erlang VM](https://medium.com/erlang-battleground/10-ways-to-stop-an-erlang-vm-7016bd593a5)).
- `Application.prep_stop/1` + `stop/1` run during a **graceful** stop (release
  upgrade, `Application.stop/1`, `:init.stop()` from a handled `SIGTERM`) —
  this is the one place code still runs before the node goes away, which is
  exactly why it's the right hook to record "we're stopping, and here's why"
  before anything is orphaned.

**Job-queue prior art (directly analogous to `WorkflowRun`/`StepRun` recovery):**
- Oban's own `Lifeline` plugin explicitly does **not** claim to know why a job
  is orphaned — it rescues purely by elapsed time ("still executing after N
  minutes") and is honest in its docs that this is a heuristic, not a
  diagnosis ([hexdocs Lifeline](https://hexdocs.pm/oban/Oban.Plugins.Lifeline.html)). ZAQ's `StartupRecovery` already does better than
  this (it knows the node actually restarted), but then throws that
  information away by hardcoding a single fake reason.
- Rails' SolidQueue uses a **heartbeat + lease** model: each worker process
  writes a heartbeat row; a supervisor prunes processes whose heartbeat has
  expired and marks their claimed jobs failed with a distinct
  `ProcessPrunedError` — a different, honestly-named class from the
  **graceful** path, where a `QUIT` signal makes the worker return its
  in-flight jobs to the queue *itself*, before exiting ([solid_queue](https://github.com/rails/solid_queue)). This is the same
  two-path split proposed below: proactive graceful handoff vs. after-the-fact
  pruning, each labeled for what it actually is.

**Conclusion for ZAQ:** we already have both halves of this pattern
half-built (`prep_stop/1`, `interrupt_run/2`'s unused opts) and just need to
connect them, following the same graceful-vs-pruned split every other system
in this space uses — not attempt to reverse-engineer an OS-level cause from
inside a process that, by definition, didn't survive to tell us.

---

## Approach

1. **Graceful path — record the real reason before we go down.** ✅ Shipped as
   `Zaq.Application.prep_stop/1` (gated on `NodeRoles.has_any?([:engine])`)
   calling the new `Workflows.interrupt_in_flight_runs/1`, default `reason:
   "graceful_shutdown"`. **No clean-stop marker was built** — see Decisions
   Log: if this call runs to completion, every in-flight run is already
   interrupted, so `StartupRecovery`'s next-boot sweep (`list_stale_runs/1`)
   finds nothing left over. The absence of stale rows *is* the "was this
   clean" signal; a separate flag would be redundant.
2. **Crash path — stop pretending we know, but capture what's actually
   knowable.** ✅ Shipped: `RunRecoveryWorker.perform/1` now passes
   `reason: "unplanned_termination"` with an honest message ("No clean
   shutdown was recorded... the process likely crashed or was killed")
   instead of "node_shutdown"/"Server restarted". **The `erl_crash.dump`
   check was descoped** — see Decisions Log (an external `SIGKILL`, the more
   common on-prem cause, never produces one anyway, and the cwd isn't
   guaranteed consistent across deployment styles).
3. **Batch/map context.** If the orphaned `StepRun` belongs to a `"map"` node
   (the exact shape the user called out — batches inside a workflow are the
   most likely thing to actually cause an OOM-kill), include that in the
   message: "was processing a batch of items (map node) when the process
   stopped — if this recurs, check `max_items`/batch size." This makes the
   error actionable instead of generic.
4. Thread real `reason`/`message` through `interrupt_run(run, reason:,
   message:)` instead of the current hardcoded map — this is additive to the
   existing `errors` shape, so `errors["reason"]` remains a string other
   consumers (`run.interrupted` event, tests) can rely on; only the *value*
   changes from a fixed lie to one of a small, honest, closed set.
5. Do **not** attempt OS-level OOM detection (parsing `dmesg`/cgroup files)
   from inside the app for v1 — per the research above, that signal lives
   outside the BEAM and On-prem deployments vary (systemd vs Docker vs bare
   metal) too much to reliably automate in this pass. Log a clear pointer
   instead: when `reason: "unplanned_termination"`, the BO message should
   suggest operators check `journalctl`/`dmesg` around the `finished_at`
   timestamp for the real OS-level cause. Automating that correlation is a
   candidate follow-up, not part of this plan.
6. The BO display work from the original draft of this plan (a shared
   render-time humanizer so the LiveViews show one consistent sentence
   instead of 3 divergent raw-inspect call sites) is still needed, but now
   has honest, distinct reasons to render instead of one fake one — kept as
   the final step here.

---

## Steps

- [x] Step 1: Wire `prep_stop/1` to proactively interrupt in-flight runs
      (**simplified** — no marker needed, see Decisions Log)
  - Module placement check: `Zaq.Application.prep_stop/1` gates on
    `Zaq.NodeRoles.has_any?([:engine])` and calls the new
    `Workflows.interrupt_in_flight_runs/1`; the interrupt logic itself lives
    in `Zaq.Engine.Workflows`, not in `Application` directly.
  - Read `docs/services/system-config.md` — decided **against** using
    `system_configs` for a marker; see Decisions Log.
  - Temporary code? no
  - Tests added: `test/zaq/application_test.exs` (`prep_stop/1` on
    engine-role vs non-engine-role node), `test/zaq/engine/workflows_test.exs`
    (`interrupt_in_flight_runs/1` — default reason, custom opts, no-op when
    nothing stale)
    - [x] Integration test(s): `prep_stop/1` with an in-flight run present →
          run/step end up `"interrupted"`/`"failed"` with `reason:
          "graceful_shutdown"`
    - [x] Branch/path coverage: no in-flight runs (no-op), multiple
          runs/mixed statuses (running/pending/completed), non-engine-role
          node (must not touch runs it doesn't own)
    - [x] Permission/security paths: n/a
    - [x] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%`
- [x] Step 2: Honest crash-path reason in `RunRecoveryWorker`/`interrupt_run/2`
      (**scoped down** — no crash-dump/`erl_crash.dump` check; see Decisions Log)
  - Module placement check: `interrupt_run/2` in `lib/zaq/engine/workflows.ex`
    now has real callers using its `opts` param;
    `RunRecoveryWorker.perform/1` passes `reason: "unplanned_termination"`
    explicitly (the bare no-opts default on `interrupt_run/2` itself is
    unchanged — kept as `"node_shutdown"` for backward compat / other
    callers with no better info).
  - Tests added: `test/zaq/engine/workflows/run_recovery_worker_test.exs`
    (asserts `reason: "unplanned_termination"` on the recovered step)
    - [x] Integration test(s): boot-sweep path (`RunRecoveryWorker.perform/1`)
          → `reason: "unplanned_termination"`
    - [ ] `erl_crash.dump` presence check — **not implemented**, descoped
          (see Decisions Log)
    - [x] Permission/security paths: n/a
    - [x] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%`
- [ ] Step 3: Batch/map context in the interruption message
  - Module placement check: lives alongside Step 2's message-building logic
    in `Zaq.Engine.Workflows`.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): orphaned `StepRun` on a `"map"` node produces a
          message mentioning batch/`max_items`; non-map node does not
    - [ ] Branch/path coverage: map node vs regular action/agent node
    - [ ] Permission/security paths: n/a
    - [ ] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%`
- [ ] Step 4: Shared BO display formatting for the (now honest) reason set
  - Module placement check: `lib/zaq/engine/workflows/error_humanizer.ex`,
    called only from the BO LiveView layer (`workflow_components.ex`,
    `workflow_run_live.ex`), consolidating the 3 currently-divergent raw
    `inspect/2` call sites identified in the original audit.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): one render test per reason
          (`graceful_shutdown`, `unplanned_termination` with/without crash
          dump, `timeout`, map-batch context, human rejection passthrough)
    - [ ] Branch/path coverage: single-step vs per-fork (map) failure display
    - [ ] Permission/security paths: n/a
    - [ ] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%`

---

## Decisions Log

| Decision | Rationale | Date |
| -------- | --------- | ---- |
| Graceful-stop vs unplanned-death split, not a single "smarter guess" | Matches the pattern every system researched uses (Oban Lifeline, SolidQueue heartbeat+lease, systemd watchdog, k8s lastState.reason) — nobody tries to diagnose a hard kill from inside the dead process; they record what they know when they know it (at graceful-stop time) and honestly flag the rest as unplanned | 2026-07-02 |
| No OS-level OOM/dmesg parsing in this pass | That signal lives outside the BEAM process and on-prem deployment targets vary (systemd/Docker/bare metal); log a pointer for operators instead of building fragile per-platform detection | 2026-07-02 |
| Reuse `interrupt_run/2`'s existing `opts` param instead of a new function signature | It was already designed for this and is currently discarded — extending it is smaller than a parallel path | 2026-07-02 |
| Keep the display-humanizer step from the original plan draft, moved to last | It's still useful once there's more than one honest reason to render, but it was solving the wrong problem as the *first* fix — cosmetic polish on top of a fabricated reason doesn't help anyone | 2026-07-02 |
| Dropped the "clean-stop marker" mechanism entirely (Step 1) | Re-read the actual boot-sweep query (`list_stale_runs/1` = any run still `"running"`/`"pending"`) while implementing: if `interrupt_in_flight_runs/1` (called from `prep_stop/1`) runs to completion, it already interrupts everything, so nothing is left stale at next boot — the *absence* of stale runs already proves the last stop was clean. A separate marker would only ever tell us what the stale-run query already tells us for free. Resolves the open Blocker outright — no `system_configs` decision needed. | 2026-07-02 |
| Descoped the `erl_crash.dump` check from Step 2 | Lower confidence/value for the effort: cwd for the dump file isn't guaranteed consistent across on-prem deployment styles (systemd/Docker/bare metal), and an external `SIGKILL` (the far more common on-prem crash cause per the State-of-the-Art research) never produces one anyway — so the check would rarely fire in the cases it's meant to help with. `reason: "unplanned_termination"` with an honest "no clean shutdown was recorded" message ships without it; can be added later as a pure addition if it proves valuable. | 2026-07-02 |
| `RunWatcher`'s live-crash path (not originally in this plan's scope) was fixed in the same pass as Step 1/2 | `RunWatcher.handle_driver_down/2` already had the real `:DOWN` exit reason in hand and was logging it, then discarding it before calling `interrupt_run/1` with no opts — the same class of bug this plan targets, just via a call site this plan's Context section never listed. Now passes `reason: "process_terminated"` with the real exit reason (`Exception.message/1` for a crash, a plain-language gloss for `:killed`, `inspect/1` fallback otherwise). See `git log` on `lib/zaq/engine/workflows/run_watcher.ex` for the change. | 2026-07-02 |
| The `finalize/2` "crash cursor" bug (run shows `"failed"` while a step stays `"running"` forever) was fixed in the same pass, though it's a distinct bug outside this plan's original scope | Client-reported: `WorkflowRunAgent.finalize/2` correctly fails the *run* when a `StepRun` is stuck `"running"`, but never resolved the *step* itself. Fixed via new `Workflows.fail_orphaned_step_runs/2` (`reason: "orphaned_step"`), called from the same crash-cursor branch. Not part of this plan's Goal (that's about honest interruption *causes*, this is about a stuck *step row*), but adjacent enough it's worth noting here rather than leaving undocumented. | 2026-07-02 |

---

## Blockers

| Blocker | Owner | Status |
| ------- | ----- | ------ |
| none currently — the clean-stop-marker blocker was resolved by dropping the marker (see Decisions Log) | — | resolved |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing
- [ ] Integration tests cover key branches/paths
- [ ] Any mocks are limited to edge external API calls (filesystem crash-dump check)
- [ ] Coverage for every added/modified file is `>= 95%`
- [ ] `mix precommit` passes
- [ ] Relevant docs updated (`docs/services/workflows.md` — document the honest reason set and the graceful/unplanned split)
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable (n/a — not tracked there)
- [ ] Plan moved to `docs/exec-plans/completed/`
