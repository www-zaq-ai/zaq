# PR Review Category Plans

Take an existing PR review plan (produced by `/pr-review-plan`), split it by category, and write one detailed implementation plan per category to `docs/exec-plans/active/pr-<number>-plan-<category>.md`. Then update the main review plan with a table linking to each category plan.

Usage: `/pr-review-category-plans <PR number>` — if no number is given, detect it from the current branch.

---

## Steps

### 1. Resolve the PR number and locate the review plan

If `$ARGUMENTS` is provided, use it as the PR number.
Otherwise run:

```sh
gh pr view --json number --jq '.number'
```

The source file is `docs/exec-plans/active/pr-<number>-review-plan.md`.

If the file does not exist, **stop** and tell the user to run `/pr-review-plan <number>` first. Do not regenerate the review yourself — this command consumes the review plan, it does not produce one.

### 2. Parse the review plan

Read the review plan and extract:

- The **Summary table** — which categories have count > 0.
- Every **comment entry** under each `## Category:` section (reviewer, location, raw quote, "What to fix", "Implementation note").
- The **Implementation Order** section — preserve its sequencing decisions inside each category plan.

Category → slug mapping (used in filenames):

| Category | Slug |
|---|---|
| Bug / Correctness | `bug` |
| Architecture / Design | `arch` |
| Tests | `tests` |
| Code Quality | `quality` |
| Documentation | `docs` |
| Security | `security` |
| Performance | `perf` |
| Nitpick / Optional | `nit` |

Skip categories with count 0 — no empty plan files.

**Reconciliation rule:** the sum of comment entries across all generated category plans must equal the "categorized" count in the review plan's Reconciliation line. If it doesn't, you missed entries — go back and find them.

### 3. Investigate the codebase before writing each plan

A category plan must be **executable without re-reading the PR**. For each comment in the category, verify against the actual code (use `ctx_batch_execute` / `ctx_execute_file` so raw file content stays in the sandbox):

- Confirm the file and line still exist (the branch may have moved since the review).
- Identify the exact module/function to change.
- Identify ripple effects: callers, tests, registry entries, docs that must change together.

If a comment no longer applies (code already changed/removed), keep it in the plan but mark its status as `obsolete` with a one-line justification — never silently drop it.

### 4. Write one plan file per category

For each non-empty category, write `docs/exec-plans/active/pr-<number>-plan-<slug>.md` with this structure:

```markdown
# PR #<number> — <Category Name> Implementation Plan

**Parent:** [pr-<number>-review-plan.md](pr-<number>-review-plan.md)
**Category:** <category> (<N> comments)
**Generated:** <today's date>

---

## Scope

<2–4 sentences: what this category covers for this PR, the common theme across
its comments, and what is explicitly out of scope (handled by sibling plans —
name them).>

## Dependencies

- **Blocked by:** <sibling category plans that must land first, with reason — e.g.
  "arch plan step 5 renames the modules these tests touch">. Write "None" if independent.
- **Blocks:** <sibling plans waiting on this one>. Write "None" if nothing depends on it.

---

## Tasks

### Task 1 — <short imperative title>
**Source comment(s):** Comment N (@reviewer, `path/to/file.ex:LINE`)
**Status:** `todo` | `obsolete (<reason>)`

**Change:**
<Concrete description of the edit: which module/function, what the code does
now, what it must do after. Reference exact names — no "update the relevant
function".>

**Files:**
- `path/to/file.ex` — <what changes here>
- `test/path/to/file_test.exs` — <test to add/update>

**Verification:**
<How to prove this task is done: the specific test case, the command, or the
observable behavior. Per docs/testing-approach.md, name the property test if
the change touches an invariant.>

---
*(repeat for each task; group comments that share one fix into one task,
listing every source comment so reconciliation still adds up)*

---

## Execution Order

1. Task N — <reason it goes first>
2. ...

## Definition of Done

- [ ] All tasks `todo` → done; `obsolete` tasks have a written justification
- [ ] New/updated tests cover every change (target ≥95% on touched code)
- [ ] `mix format` run on every touched file
- [ ] `mix q` passes
- [ ] Parent review-plan table status updated for this category
```

Plan-quality requirements:

- Every task names exact modules/functions — a future session must be able to execute it without re-fetching the PR comments.
- Honor repo rules in the tasks themselves: cross-service BO calls go through `NodeRouter.dispatch/1` with `%Zaq.Event{}`; read a module's `@moduledoc` before adding functions to it; secrets/config work requires reading `docs/services/system-config.md` first.
- The `nit` plan is the only one allowed to have an "apply or decline" decision per task instead of a mandatory change.

### 5. Update the main review plan

Edit `docs/exec-plans/active/pr-<number>-review-plan.md`: insert an `## Implementation Plans` section **immediately after the Summary section** (before `## Excluded`), containing:

```markdown
## Implementation Plans

Each category has a standalone implementation plan. Execute them in the order below.

| # | Category | Comments | Plan file | Status |
|---|---|---|---|---|
| 1 | Security | N | [pr-<number>-plan-security.md](pr-<number>-plan-security.md) | not started |
| 2 | Bug / Correctness | N | [pr-<number>-plan-bug.md](pr-<number>-plan-bug.md) | not started |
| ... | | | | |
```

- Order the rows by execution priority (severity + dependencies), consistent with the review plan's Implementation Order: `security` and `bug` first, then `arch`, `tests`, `perf`, `quality`, `docs`, `nit` — adjusted if a dependency between plans dictates otherwise.
- Status values: `not started` | `in progress` | `done` | `n/a`. This command always writes `not started`; later sessions update it as plans are executed.
- If the section already exists (re-run), **replace** it in place — do not duplicate it.
- Do not modify any other part of the review plan.

### 6. Print the result

After writing all files, print:

- One line per category plan: `[slug] N comments → docs/exec-plans/active/pr-<number>-plan-<slug>.md`
- The reconciliation line: `<sum of tasks' source comments> entries across <K> plans = <categorized count in review plan>` — these must match.
- Confirmation that the main review plan's Implementation Plans table was added/updated.

Do not print the plan file contents — paths and the summary only.

---

## Constraints

- Do NOT start implementing any fixes — this command produces plans only.
- Do NOT inline file contents into the chat response.
- Do NOT regenerate or re-fetch PR comments — the review plan file is the single source of truth for what the reviewers said. Codebase investigation is only for making the plans concrete.
- Every comment entry in the review plan must appear in exactly one category plan (as a task source, possibly shared with other comments in one task, or marked `obsolete`). No silent drops.
- Skip categories with 0 comments entirely — no empty files, no table rows for them.
- On re-run: overwrite existing category plan files and replace the Implementation Plans table in place — never append duplicates. If a category plan's status in the table is `in progress` or `done`, preserve that status instead of resetting it to `not started`.
