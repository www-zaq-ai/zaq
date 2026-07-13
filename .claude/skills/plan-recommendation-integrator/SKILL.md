---
name: plan-recommendation-integrator
description: Takes the tagged Recommendations list produced by the implementation-plan-reviewer skill and merges each recommendation into the original implementation plan document, at the correct section, in the plan's own voice. Use this whenever the user has a plan review with a "## Recommendations" list (tags like [ARCH], [ABSTRACTION], [EDGE-CASE], [TEST], [QUESTION]) and wants those recommendations folded into the plan itself, or asks to "update the plan with the review feedback" / "apply the recommendations" / "merge the review into the plan."
---

# Plan Recommendation Integrator

Merge reviewer recommendations into an implementation plan document, producing an updated plan — not a second report sitting next to the first one.

## Inputs required

1. The original implementation plan (the document being updated).
2. The Recommendations list from a plan review (tagged lines: `[ARCH]`, `[ABSTRACTION]`, `[EDGE-CASE]`, `[TEST]`, `[QUESTION]`).

If either is missing, ask for it rather than guessing — do not fabricate recommendations, and do not merge against a plan you haven't seen in full.

## Process

1. **Match each recommendation to its section.** Each recommendation references the plan section or feature it applies to. Find that section in the plan. If a recommendation doesn't cleanly map to an existing section, create a new subsection rather than bolting it onto an unrelated one.

2. **Route by tag:**
   - `[ARCH]` / `[ABSTRACTION]` → fold into the relevant design/approach section, rewritten as part of the plan's own description (not quoted as "reviewer said...").
   - `[EDGE-CASE]` → add to (or create) an "Edge Cases" list under the relevant feature, as a concrete case with expected behavior, not just a restated tag.
   - `[TEST]` → add to (or create) a "Tests" section that precedes the implementation steps for that feature — this is what makes the plan TDD-ordered. Test cases go in before the corresponding implementation step, never after.
   - `[QUESTION]` → add to (or create) an "Open Questions" section at the top of the plan, kept separate from committed decisions. Never silently resolve a question by picking an answer — flag it for the plan owner to decide.

3. **Write in the plan's voice.** Rewrite each recommendation as a natural part of the document — a design decision, a test case, an edge case entry — not as a citation of the review. The merged plan should read as if it were written this way from the start.

4. **Preserve everything not touched by a recommendation.** This is an update, not a rewrite. Don't restructure sections the review didn't flag, don't drop existing content, and don't change wording outside of what a recommendation requires.

5. **Ordering check before finishing.** Confirm every `[TEST]` recommendation's test case appears before its matching implementation step. If the plan didn't have an explicit ordering, add one — tests first is the point.

## Output

- Produce the full updated plan document (not a diff, not a partial excerpt) so it can replace the original.
- At the end, include a short **Changelog** section listing which recommendations were applied and where, so the plan owner can verify nothing was missed or misplaced:
  ```markdown
  ## Changelog (from plan review)
  - [ARCH] ... → applied to [section]
  - [TEST] ... → applied to [section]
  ```
- If a recommendation couldn't be placed confidently, list it under "Unplaced — needs manual placement" in the changelog instead of guessing.

## Notes

- Never silently drop a recommendation. Every item in the Recommendations list must appear in the Changelog as either applied or unplaced.
- If the same recommendation seems to apply to multiple sections, apply it to the most specific one and note the overlap in the changelog rather than duplicating the text across sections.