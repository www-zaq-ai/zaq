# Execution Plan: Workflow Action Log Trail & Error Humanization

**Date:** 2026-07-02
**Author:** Claude (session continuation)
**Status:** `active`
**Related debt:** New — discovered `Zaq.Accounts.People.create_partial_person/2` bug during this work (see Blockers)
**PR(s):** none yet — all work is on branch `feat/workflow-bo-screens`, uncommitted

---

## Goal

Every action reachable from a workflow node must (a) contribute a log entry to
the step's log trail when run inside a workflow (`context` carries `:run_id`),
and (b) produce a human-readable error string — never a raw `inspect()`/struct
dump — since both are rendered verbatim in the BO run view
(`lib/zaq_web/live/bo/ai/workflow_run_live.ex`).

Audited all 26 modules implementing `Zaq.Engine.Workflows.Action`. Two
`lib/zaq/agent/tools/workflow/*` actions (`run_agent.ex`, `dispatch_event.ex`)
and the shared `Action` behaviour are done. `notify_person.ex` /
`ensure_person.ex` are the last two actions needing this treatment; a shared
`Zaq.Agent.Tools.Error` formatter needs one more clause (`%Ecto.Changeset{}`)
to support them.

Done looks like: `notify_person.ex` and `ensure_person.ex` return humanized
errors and 3-tuple log trails exactly like `run_agent.ex`/`dispatch_event.ex`
already do; `mix q` is green.

---

## Context

- Existing code reviewed: `lib/zaq/engine/workflows/step_runner.ex`,
  `lib/zaq/engine/workflows/action.ex`, `lib/zaq/agent/tools/workflow/run_agent.ex`,
  `lib/zaq/agent/tools/workflow/dispatch_event.ex`, `lib/zaq/agent/tools/data_source_tool.ex`,
  `lib/zaq/agent/tools/error.ex`, `lib/zaq/agent/tools/people/notify_person.ex`,
  `lib/zaq/agent/tools/people/ensure_person.ex`, `lib/zaq/accounts/people.ex`,
  `lib/zaq/accounts/person.ex`, `lib/zaq_web/changeset_errors.ex`.

### Infrastructure Audit

- Existing entry points checked: `Zaq.Engine.Workflows.Action.log_start/0`,
  `log_entry/2,3`, and the new `with_log_trail/5` (already implemented and
  tested) are the single mechanism for the 3-tuple log-trail contract. No new
  helper needed — `notify_person`/`ensure_person` just need to call it.
- `@moduledoc` read for every module receiving new code: yes for
  `error.ex`, `notify_person.ex`, `ensure_person.ex`.
- No parallel code path being created: confirmed — reusing
  `Zaq.Agent.Tools.Error.format/1` (already used by `DataSourceTool`) and
  `Action.with_log_trail/5` (already used by `run_agent.ex`/`dispatch_event.ex`).
  `ZaqWeb.ChangesetErrors` (web layer) is deliberately **not** reused from
  `lib/zaq/agent/tools/error.ex` — core code must not depend on the web layer.
- Provider/credential/URL logic: n/a.

---

## Approach

Same TDD pattern used for `run_agent.ex`/`dispatch_event.ex`: red (write/fix
failing tests) → green (implement) → verify (`mix format`, `mix q`, full test
run). Reuse the two already-built primitives (`Error.format/1`,
`Action.with_log_trail/5`) rather than inventing new ones.

---

## Steps

- [x] Step 0: Build `Action.with_log_trail/5` and prove it via `run_agent.ex` +
      `dispatch_event.ex`. **Done** — `lib/zaq/engine/workflows/action.ex`,
      `lib/zaq/agent/tools/workflow/run_agent.ex`,
      `lib/zaq/agent/tools/workflow/dispatch_event.ex`, plus their tests and
      `test/zaq/engine/workflows/action_test.exs`,
      `test/zaq/engine/workflows/condition_trigger_failure_test.exs`,
      `test/zaq_web/live/bo/ai/workflow_run_live_test.exs`. Full suite green
      (97 tests, 0 failures) at time of writing.

- [ ] Step 1: Add `%Ecto.Changeset{}` clause to `Zaq.Agent.Tools.Error.to_message/1`
  - Module placement check: `lib/zaq/agent/tools/error.ex` — this is the
    single shared error-humanization module already used by
    `DataSourceTool`; changeset support belongs here, not duplicated.
  - Implementation: add a `to_message(%Ecto.Changeset{} = changeset)` clause
    **before** the generic `%_{} = exception` clause. Traverse
    `changeset.errors` (or `Ecto.Changeset.traverse_errors/2`) and join into
    prose, e.g. `"channel_identifier can't be blank"`. Do not import
    `ZaqWeb.ChangesetErrors` (web→core boundary violation) — replicate the
    minimal logic inline.
  - Temporary code? no
  - Tests to add before implementation: already written —
    `test/zaq/agent/tools/error_test.exs` `"formats an Ecto.Changeset's errors
    as readable prose, not a struct dump"` (currently failing for the right
    reason — raw `#Ecto.Changeset<...>` dump). No new test needed, just make
    it pass.
  - Coverage target: `>= 95%` (single new clause, one test already covers it)

- [ ] Step 2: Fix the false-premise test in `ensure_person_test.exs` **before**
      touching `ensure_person.ex`
  - Problem: the `"run/2 — data-layer failure"` test
    (`test/zaq/agent/tools/people/ensure_person_test.exs:145-156`) assumes
    `EnsurePerson.run(%{platform: "mattermost", display_name: "No Identifier"}, @ctx)`
    returns `{:error, %Ecto.Changeset{}}` because the new `PersonChannel`'s
    `channel_identifier` would be blank. It actually returns `{:ok, ...}`
    because `Zaq.Accounts.People.create_partial_person/2` (lib/zaq/accounts/people.ex:548-572)
    calls `add_channel/1` inside its `Repo.transaction` block but never checks
    the return value — a failed channel-link is silently swallowed and the
    transaction still commits. This is a **pre-existing bug in `People`**,
    out of scope for this plan (see Blockers).
  - Resolution: rewrite the test to not depend on that unreachable path.
    Two sub-options, pick one during implementation:
    - (a) Drop the integration-style "data-layer failure" test entirely and
      rely on the already-correct `Error.format/1` unit coverage
      (`error_test.exs`) for the formatting behavior; add a narrower unit
      test that stubs `People.find_or_create_from_channel/2` (e.g. via a
      test double module, matching the `OkRouter`/`ErrorRouter` pattern
      already used in `notify_person_test.exs`) to return
      `{:error, %Ecto.Changeset{}}` directly, proving `EnsurePerson.run/2`
      formats whatever `People` gives it.
    - (b) File a follow-up tech-debt item for the `People` bug and use a
      genuine (if awkward) concurrent-race or manually-inserted-conflicting-row
      setup to trigger the real unique_constraint path. Likely more fragile;
      prefer (a) unless the user asks for the `People` fix in scope.
  - Module placement check: test file only, no production module change here.
  - Temporary code? no
  - Coverage target: n/a (test-only step)

- [ ] Step 3: Implement `notify_person.ex` fix
  - Module placement check: `lib/zaq/agent/tools/people/notify_person.ex` —
    error humanization and log trail both belong on the action itself,
    matching `run_agent.ex`/`dispatch_event.ex`.
  - Implementation:
    - Replace `{:error, "missing_person_id"}` with a humanized message
      containing "person id" (see test assertion at
      `notify_person_test.exs:110-119`).
    - Replace `{:error, "notify_person_failed:#{inspect(other)}"}` with
      `"Notify person failed: #{inspect(other)}"` prose (test assertion at
      `notify_person_test.exs:96-108`).
    - Wrap the success path with `Action.with_log_trail(result, :person_notified,
      %{person_id: id}, context, t0)`, capturing `t0 = Action.log_start()` near
      the top of `run/2`.
  - Temporary code? no
  - Tests to add before implementation: already written in
    `test/zaq/agent/tools/people/notify_person_test.exs` — confirmed 3 of 4
    new/changed tests fail for the expected "not yet implemented" reason.
  - Coverage target: `>= 95%`

- [ ] Step 4: Implement `ensure_person.ex` fix
  - Module placement check: `lib/zaq/agent/tools/people/ensure_person.ex`.
  - Implementation:
    - Rename `_ctx` param to `ctx` (needed to check `:run_id`).
    - Replace `{:error, inspect(reason)}` with `{:error, Error.format(reason)}`.
    - Wrap the success path with `Action.with_log_trail({:ok, %{person: ...,
      row: ...}}, :person_ensured, %{platform: platform, person_id: person.id},
      ctx, t0)`.
  - Temporary code? no
  - Tests to add before implementation: already written in
    `test/zaq/agent/tools/people/ensure_person_test.exs` — the
    `"run/2 — action log trail (workflow node)"` block (lines 162-180) is
    correctly designed and just needs the implementation. The "data-layer
    failure" test must be resolved per Step 2 first.
  - Coverage target: `>= 95%`

- [ ] Step 5: Full verification
  - Run `mix format`.
  - Run the four affected test files directly, then `mix q` (full quality
    gate — format check, credo, tests, coverage). Confirm the two pre-existing,
    unrelated failures in `dispatch_fifty_items_test.exs` (module
    `Zaq.Engine.Workflows.UseCases.DispatchFiftyItems` does not exist) are
    still the only remaining failures, or that they've since been fixed by
    someone else.
  - Report results back to the user: files touched, test counts, and a note
    on the `People` bug discovery / how Step 2 was resolved.

---

## Decisions Log

| Decision | Rationale | Date |
| -------- | --------- | ---- |
| Do not import `ZaqWeb.ChangesetErrors` into `lib/zaq/agent/tools/error.ex` | Core (`lib/zaq/`) must not depend on the web layer (`lib/zaq_web/`); replicate minimal changeset-to-prose logic inline instead | 2026-07-02 |
| `People.create_partial_person/2`'s silent `add_channel` failure is out of scope | Discovered while writing a test for `EnsurePerson`'s error path; fixing `People` is a separate concern from humanizing `EnsurePerson`'s existing error branch | 2026-07-02 |

---

## Blockers

| Blocker | Owner | Status |
| ------- | ----- | ------ |
| `Zaq.Accounts.People.create_partial_person/2` (lib/zaq/accounts/people.ex:548-572) calls `add_channel/1` inside its `Repo.transaction` but never checks the return value, so a channel-link validation failure (e.g. blank `channel_identifier`) is silently swallowed and the transaction commits anyway. Same issue for `ensure_channel_linked/...`'s discarded return in the "existing person matched" branch (~line 135). This makes `EnsurePerson`'s `{:error, %Ecto.Changeset{}}` branch effectively unreachable through the real public API for the scenario the original test assumed. | unassigned | open — tracked here; not yet added to `docs/exec-plans/tech-debt-tracker.md` |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing (`error_test.exs`, `notify_person_test.exs`,
      `ensure_person_test.exs`, plus no regression in the 97 tests already
      green from Step 0)
- [ ] Integration tests cover key branches/paths
- [ ] Any mocks are limited to edge external API calls
- [ ] Coverage for every added/modified file is `>= 95%`
- [ ] `mix q` passes (excluding the pre-existing, unrelated
      `dispatch_fifty_items_test.exs` failures, unless fixed incidentally)
- [ ] Relevant docs updated (n/a expected — no public API/doc surface changes)
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] `People.create_partial_person/2` bug logged in
      `docs/exec-plans/tech-debt-tracker.md` (new item, not fixed as part of
      this plan)
- [ ] Plan moved to `docs/exec-plans/completed/`
