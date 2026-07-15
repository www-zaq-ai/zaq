---
name: pr-review-fixer
description: Reads a saved PR review markdown file from docs/exec-plans/review/ and fixes every finding it contains — all inline comments and all general comments, across every severity level. Use this skill whenever the user asks to fix, address, resolve, or apply findings from a PR review, asks to "fix the review comments," or references a review file previously produced by the pr-review-agent skill. Must not stop after fixing only some findings; tracks every finding to completion and reports a final status for each one, verifying that nothing is left outstanding before finishing.
---

# PR Review Fixer

Read a saved PR review and fix **every** finding in it — no partial passes, no skipping low-severity items, no leaving anything "for later" unless the user explicitly says so.

## Step 1: Locate and read the review file

- Look in `docs/exec-plans/review/` for the relevant review markdown file (named `<pr-number-or-branch>-review.md`).
- If the user names a specific PR/branch, use that file. If there's only one file in the folder, use it. If there are multiple and it's ambiguous which one the user means, ask.
- If the folder or file doesn't exist, tell the user directly — do not invent findings.
- Read the full file, including Section A (inline comments), Section B (general comments), and Section C (recap), so you have the true total count of findings to fix.

## Step 2: Build a findings checklist

Before touching any code, extract every individual finding into a checklist, e.g.:

```
- [ ] (high) file.ex:42 — <title>
- [ ] (medium) file.ex:88 — <title>
- [ ] (low) general — <title>
...
```

This checklist is the source of truth for completion. Every item in it — regardless of severity — must end as fixed, or explicitly justified as a non-fix (see Step 5). Do not silently drop low-severity items.

## Step 3: Fix findings in order

Work through the checklist high → medium → low severity:

- For each finding, make the concrete code change described in the review's "suggested fix" / "recommendation."
- If the suggested fix is ambiguous or there are multiple valid approaches, choose the one most consistent with existing patterns in the surrounding code.
- If a finding depends on another finding being fixed first (e.g. a helper must be extracted before duplicate call sites can use it), fix the dependency first.
- After each fix, re-check surrounding code the change touches to avoid introducing a new instance of the same problem elsewhere.
- Do not fix unrelated issues you happen to notice along the way — stay scoped to what's in the review file. If you spot something clearly important but out of scope, note it at the end rather than fixing it silently.

## Step 4: Verify

After all checklist items are addressed:

- Re-read the diff/changed files against each checklist item and confirm the described problem no longer exists.
- Run the project's existing test suite / linter if one is available and applicable, and fix any regressions your changes introduced.
- Confirm no finding was silently skipped. If the checklist has any item not marked fixed, go back to Step 3 — do not proceed to Step 5 with open items unless it's a genuine non-fix case.

## Step 5: Handle genuine non-fixable findings

A finding may be left unfixed only if:
- it's factually incorrect (re-reading the code shows the problem doesn't actually exist), or
- fixing it requires a decision only the user can make (e.g. a breaking API/schema change, a product/UX call, credentials/config the user must supply)

In either case, mark it clearly in your final report as "not fixed" with the specific reason — never leave it silently unaddressed.

## Step 6: Report

Produce a final summary:

1. **Totals** — findings found, findings fixed, findings not fixed (with reasons)
2. **Fix list** — one line per finding: severity, file/location, what was changed
3. **Verification** — what was checked (tests/lint run and result) to confirm the fixes hold
4. **Any out-of-scope issues noticed** but intentionally not fixed

If the user wants the fixes documented back in the review file, append a "Resolution" note to each finding in the `docs/exec-plans/review/<...>-review.md` file (fixed / not fixed + reason) rather than deleting the original findings.

## Constraints

- Fix all findings in the review file — partial completion is not acceptable unless a finding falls under Step 5's genuine non-fixable cases.
- Do not modify code outside what's needed to address the findings.
- Do not remove or rewrite the original review file's findings — only annotate resolution status if asked.
- Keep changes minimal and targeted to each finding's described problem.