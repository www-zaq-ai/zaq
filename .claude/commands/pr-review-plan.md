# PR Review Plan

Fetch all reviewer comments from a pull request, categorize them, and write a structured implementation plan to `docs/exec-plans/active/pr-<number>-review-plan.md`.

Usage: `/pr-review-plan <PR number>` — if no number is given, detect it from the current branch.

---

## Steps

### 1. Resolve the PR number

If `$ARGUMENTS` is provided, use it as the PR number.
Otherwise run:

```sh
gh pr view --json number --jq '.number'
```

If that also fails, stop and ask the user for the PR number.

### 2. Fetch all reviewer feedback

**Always use `gh api --paginate`** — without it, GitHub returns only the first 30 items and the rest are silently dropped. Never use `gh pr view --json reviews/comments` for this; it also truncates.

Run these commands (all output stays in the sandbox via `ctx_batch_execute`):

```sh
# Top-level review bodies (approve/request-changes messages)
gh api --paginate repos/{owner}/{repo}/pulls/<PR>/reviews \
  --jq '.[] | {id: .id, author: .user.login, state: .state, body: .body}'

# Inline review thread comments (line-level)
gh api --paginate repos/{owner}/{repo}/pulls/<PR>/comments \
  --jq '.[] | {id: .id, in_reply_to_id: .in_reply_to_id, author: .user.login, path: .path, line: (.line // .original_line), body: .body}'

# General (non-review) PR comments
gh api --paginate repos/{owner}/{repo}/issues/<PR>/comments \
  --jq '.[] | {id: .id, author: .user.login, body: .body}'
```

Resolve `{owner}/{repo}` from:
```sh
gh repo view --json nameWithOwner --jq '.nameWithOwner'
```

Notes on the data:
- `line` is `null` for comments on outdated diffs — that's why the jq falls back to `original_line`. These comments are still actionable; never drop them.
- Comments with `in_reply_to_id` set are **replies within a thread** — group them under their root comment instead of counting them as separate findings. The whole thread is one finding; later replies may refine or withdraw it.

### 2b. Record the expected totals (reconciliation baseline)

Before categorizing, count what was fetched:

```sh
gh api --paginate repos/{owner}/{repo}/pulls/<PR>/comments | jq -s 'add | map(select(.in_reply_to_id == null)) | length'
```

Note three numbers: **R** = reviews with non-empty bodies, **I** = inline root comments (excluding replies), **G** = general comments. Every one of these must be accounted for in the plan — either categorized or listed in the "Excluded" section with a reason. If the plan's totals don't add up to R + I + G, you missed comments: go back and find them.

### 3. Categorize every comment

Go through each comment (top-level review body, inline thread, general comment) and assign it to **one** primary category:

| Category | Label | What belongs here |
|---|---|---|
| Bug / Correctness | `bug` | Will break at runtime, wrong logic, incorrect return value |
| Architecture / Design | `arch` | Module boundary violations, NodeRouter bypasses, coupling, wrong abstraction |
| Tests | `tests` | Missing test cases, weak assertions, wrong test layer |
| Code Quality | `quality` | Naming, duplication, complexity, dead code, anti-patterns |
| Documentation | `docs` | Missing `@doc`, `@moduledoc`, outdated `docs/services/*.md` sections |
| Security | `security` | Auth gaps, nil person_id paths, missing input validation, exposed secrets |
| Performance | `perf` | N+1 queries, unnecessary DB calls, blocking the caller |
| Nitpick / Optional | `nit` | Style preferences, minor wording — reviewer explicitly marked as optional |

A comment that fits multiple categories goes in the **most severe** one (`bug` > `security` > `arch` > `tests` > `perf` > `quality` > `docs` > `nit`).

If a single comment (especially a top-level review body) contains **multiple distinct findings**, split it into one plan entry per finding — do not collapse a multi-point review into one item.

Discard only CI/automation bot comments (Codecov, Dependabot, GitHub Actions, renovate). **Keep** comments from review bots (Copilot, CodeRabbit, Claude) — they are reviewer feedback. When in doubt, keep it.

### 4. Write the plan file

Write the output to `docs/exec-plans/active/pr-<number>-review-plan.md` using this exact structure:

```markdown
# PR #<number> Review Plan

**Branch:** <branch name>
**PR title:** <title>
**Reviewers:** <comma-separated list of authors who left comments>
**Generated:** <today's date>

---

## Summary

| Category | Count |
|---|---|
| Bug / Correctness | N |
| Architecture / Design | N |
| Tests | N |
| Code Quality | N |
| Documentation | N |
| Security | N |
| Performance | N |
| Nitpick / Optional | N |

**Total actionable comments:** N (excludes nits)
**Reconciliation:** fetched R reviews + I inline threads + G general comments = T; T categorized + E excluded = T ✓

---

## Excluded

*(omit if empty — list every fetched comment that did not become a plan entry, with the reason)*

| Author | Location | Reason excluded |
|---|---|---|
| @bot | — | CI bot (Codecov) |
| @author | `file.ex:12` | Empty approval body |
| @author | `file.ex:40` | Reply within thread of Comment 3 |

---

## Category: Bug / Correctness

*(omit this section entirely if count is 0)*

### Comment N — `path/to/file.ex` line X
**Reviewer:** @author
**Raw comment:**
> <exact quote of the comment>

**What to fix:**
<1–2 sentences: what specifically needs to change and why>

**Implementation note:**
<where in the codebase to make the change; reference the exact module/function if known>

---
*(repeat for each comment in this category)*

---

## Category: Architecture / Design

*(same structure — omit if count is 0)*

---

## Category: Tests

*(same structure — omit if count is 0)*

---

## Category: Code Quality

*(same structure — omit if count is 0)*

---

## Category: Documentation

*(same structure — omit if count is 0)*

---

## Category: Security

*(same structure — omit if count is 0)*

---

## Category: Performance

*(same structure — omit if count is 0)*

---

## Category: Nitpick / Optional

*(same structure — omit if count is 0)*

---

## Implementation Order

List the actionable comments in the order they should be addressed, with the reasoning:

1. **[bug]** Fix X in `path/to/file.ex` — blocks correctness, do first
2. **[security]** Address Y — must not ship without this
3. **[arch]** Refactor Z — other steps depend on the correct structure
4. ...
*(nits go last or can be batched into a single "cleanup" step)*

---

## Definition of Done

- [ ] Every `bug` and `security` comment addressed
- [ ] Every `arch` comment addressed or explicitly accepted with rationale
- [ ] Every `tests` comment addressed (new test cases added)
- [ ] Every `quality` and `docs` comment addressed
- [ ] `Nitpick / Optional` comments reviewed — apply or explicitly decline each one
- [ ] `mix q` passes
- [ ] PR updated and re-requested review
```

### 5. Print the result

After writing the file, print:
- The file path
- The reconciliation line: `fetched T comments → N categorized + E excluded` (these must add up — if they don't, the plan is incomplete; fix it before printing)
- One line per category that has comments: `[category] N comments`
- The total count of actionable comments (non-nit)

Do not print the full file contents — only the path and the summary table above.

---

## Constraints

- Do NOT start implementing any fixes — this skill produces the plan only.
- Do NOT inline the file contents into the chat response.
- ALWAYS fetch with `gh api --paginate` — a missing flag here silently drops every comment past the first 30.
- Every fetched comment must appear in the plan: either as a categorized entry or in the Excluded table with a reason. No silent drops.
- If a comment body is empty (e.g. an "Approved" review with no text), list it in Excluded.
- If a category has zero comments, omit that section from the output file entirely.
- Nit-only PRs (all comments are `nit`) still get a plan file — the Implementation Order section will say "All comments are optional nits — address at your discretion."
