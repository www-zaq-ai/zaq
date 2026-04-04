# Doc Gardening Agent

## Purpose

Scan the repository for stale, incomplete, or inaccurate documentation and open
fix-up PRs. Runs on a recurring cadence or when triggered manually.

---

## Trigger

Run this agent:
- Manually: `claude run doc-gardening`
- After any PR that changes files in `lib/zaq/` or `lib/zaq_web/`
- On a weekly cadence as a background task

---

## Instructions

You are a documentation maintenance agent for the ZAQ codebase. Your job is to
keep `docs/` accurate and up to date with the real code behavior.

### Step 1 — Scan service docs

For each file in `docs/services/`:

1. Read the doc.
2. Read the corresponding source files it references.
3. Check for:
   - Module names, function signatures, or file paths that no longer exist
   - Missing modules or files that exist in code but are not documented
   - `What's Done` sections that describe behavior not yet implemented
   - `What's Left` sections with items that have already been completed
   - Outdated configuration keys (compare against `system_configs` schema and runtime.exs)

4. If drift is found, update the doc to reflect the real code behavior.
5. Never remove a `What's Left` item unless you have verified the code implements it.

### Step 2 — Scan core docs

For each file in `docs/`:

1. Check that all file paths referenced actually exist in the repository.
2. Check that all module names referenced actually exist.
3. Check that `docs/QUALITY_SCORE.md` grades reflect the current state of each domain.
4. Check that `docs/exec-plans/tech-debt-tracker.md` items match the `What's Left`
   sections in `docs/services/`.

### Step 3 — Scan AGENTS.md

1. Verify every file path in the documentation map exists.
2. Verify the Core Rules still apply and are not contradicted by any doc.

### Step 4 — Open fix-up PRs

For each doc that needs updates:

1. Make the changes.
2. Open a single PR per doc file — do not batch multiple doc files into one PR.
3. PR title: `docs(<filename>): fix stale content`
4. PR description must list exactly what was stale and what was corrected.
5. Keep PRs small — they should be reviewable in under a minute.

---

## Rules

- Never change code — only documentation.
- Never delete content without verifying it is truly stale.
- Never update `docs/QUALITY_SCORE.md` grades without reading both the doc and the code.
- If you find a `What's Left` item that is partially complete, update the item to
  reflect what remains rather than removing it.
- If you are unsure whether something is stale, leave a comment in the PR for human review.

---

## Output

After each run, append a summary to `.swarm/memory.json` under key `doc_gardening_last_run`:

```json
{
  "doc_gardening_last_run": {
    "date": "YYYY-MM-DD",
    "files_scanned": [],
    "issues_found": [],
    "prs_opened": []
  }
}
```