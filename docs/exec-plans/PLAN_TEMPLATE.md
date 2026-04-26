# Execution Plan Template

Copy this file to `docs/exec-plans/active/YYYY-MM-DD-short-description.md` when starting a complex task.
Move it to `docs/exec-plans/completed/` when done.

---

## Plan: [Short Title]

**Date:** YYYY-MM-DD
**Author:** [human]
**Status:** `active` | `completed` | `blocked`
**Related debt:** [link to item in tech-debt-tracker.md if applicable]
**PR(s):** [list PRs opened as part of this plan]

---

## Goal

One paragraph. What problem does this solve and what does done look like?

---

## Context

What docs were read before writing this plan? What existing code is relevant?

- [ ] `docs/architecture.md`
- [ ] `docs/conventions.md`
- [ ] `docs/services/<relevant>.md`
- [ ] Existing code reviewed: [list files]

### Infrastructure Audit

Confirm before writing any step — what already exists that this plan must use or extend?

- [ ] Existing entry points checked (Factory, Executor, builders, helpers): [list findings or `n/a`]
- [ ] `@moduledoc` read for every module that will receive new code: [list modules]
- [ ] No parallel code path being created where an existing one can be extended: [confirm or explain]
- [ ] Provider/credential/URL logic confirmed to stay in its designated module: [confirm or `n/a`]

---

## Approach

High-level description of the solution. Why this approach over alternatives?

---

## Steps

Break the work into small, independently completable steps. Each step should be
completable in a single PR. Check off as you go.

- [ ] Step 1: [description]
  - Module placement check: [which module owns this? does @moduledoc cover it?]
  - Temporary code? [yes → add `# Temporary:` comment in code | no]
  - Tests to add before implementation:
    - [ ] Integration test(s): [describe]
    - [ ] Branch/path coverage: [describe branches]
    - [ ] Permission/security paths (if applicable): [nil person_id, skip_permissions, access scope]
    - [ ] Edge external API mocks only: [describe mocks or `none`]
  - Coverage target for files touched in this step: `>= 95%`
- [ ] Step 2: [description]
  - Module placement check: [which module owns this? does @moduledoc cover it?]
  - Temporary code? [yes → add `# Temporary:` comment in code | no]
  - Tests to add before implementation:
    - [ ] Integration test(s): [describe]
    - [ ] Branch/path coverage: [describe branches]
    - [ ] Permission/security paths (if applicable): [nil person_id, skip_permissions, access scope]
    - [ ] Edge external API mocks only: [describe mocks or `none`]
  - Coverage target for files touched in this step: `>= 95%`
- [ ] Step 3: [description]
  - Module placement check: [which module owns this? does @moduledoc cover it?]
  - Temporary code? [yes → add `# Temporary:` comment in code | no]
  - Tests to add before implementation:
    - [ ] Integration test(s): [describe]
    - [ ] Branch/path coverage: [describe branches]
    - [ ] Permission/security paths (if applicable): [nil person_id, skip_permissions, access scope]
    - [ ] Edge external API mocks only: [describe mocks or `none`]
  - Coverage target for files touched in this step: `>= 95%`

---

## Decisions Log

Record decisions made during implementation. Future agents need this context.

| Decision | Rationale | Date |
| -------- | --------- | ---- |
|          |           |      |

---

## Blockers

List anything blocking progress and who/what can unblock it.

| Blocker | Owner | Status |
| ------- | ----- | ------ |
|         |       |        |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing
- [ ] Integration tests cover key branches/paths
- [ ] Any mocks are limited to edge external API calls
- [ ] Coverage for every added/modified file is `>= 95%`
- [ ] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`
