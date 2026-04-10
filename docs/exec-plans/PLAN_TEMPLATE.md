# Execution Plan Template

Copy this file to `docs/exec-plans/active/YYYY-MM-DD-short-description.md` when starting a complex task.
Move it to `docs/exec-plans/completed/` when done.

---

## Plan: [Short Title]

**Date:** YYYY-MM-DD
**Author:** [agent or human]
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

---

## Approach

High-level description of the solution. Why this approach over alternatives?

---

## Steps

Break the work into small, independently completable steps. Each step should be
completable in a single PR. Check off as you go.

- [ ] Step 1: [description]
- [ ] Step 2: [description]
- [ ] Step 3: [description]

---

## Decisions Log

Record decisions made during implementation. Future agents need this context.

| Decision | Rationale | Date |
|---|---|---|
| | | |

---

## Blockers

List anything blocking progress and who/what can unblock it.

| Blocker | Owner | Status |
|---|---|---|
| | | |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing
- [ ] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`