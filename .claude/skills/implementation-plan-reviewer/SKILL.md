---
name: implementation-plan-reviewer
description: Reviews a proposed implementation plan, technical spec, or design doc before any code gets written. Checks that the plan understands its place in the wider system, picks the right level of abstraction, covers edge cases, plans tests before implementation (TDD), and flags anything vague or architecturally ambiguous that should be clarified first. Use this whenever the user shares an implementation plan, design doc, RFC, or asks to review/critique/validate/sanity-check a plan before implementation starts. Also trigger when the user asks "does this plan look right" or "what am I missing" about a technical approach.
---

# Implementation Plan Reviewer

Review implementation plans against five checks, in order. Do not skip a check because the earlier ones looked fine — each catches a different failure mode. Work through the plan once fully before writing the report.

## The five checks

### 1. Domain and system fit
Identify what domain/subsystem this plan touches, and how that piece connects to the rest of the system: what calls it, what it calls, what data it owns, what contracts (APIs, schemas, events) it must honor. A plan that's internally consistent but ignores its neighbors will break integration later. Flag any place the plan doesn't state its inputs/outputs/dependencies clearly enough to verify this.

### 2. Abstraction level
Check whether the implementation is built to the actual ask, or is over/under-abstracted:
- **Under-abstracted**: hardcodes something that the ask (or clearly-adjacent near-term needs) requires to vary.
- **Over-abstracted**: builds generic frameworks, plugin systems, or config layers for a need that isn't there yet — speculative generality nobody asked for.
The right level is "as specific as the ask, with seams left only where the plan gives a concrete reason a seam is needed." Call out any abstraction that isn't justified by something explicit in the plan.

### 3. Edge cases
List the edge cases the plan has and hasn't considered. Think in categories, not just examples: empty/null/missing input, boundary values, concurrent access, partial failure, retries/idempotency, permission/auth edges, scale (0, 1, many), and reversibility (what happens if this needs to be undone). Don't just say "edge cases are missing" — name the specific ones relevant to this plan's domain.

### 4. TDD — tests before implementation
Check that the plan states what tests will be written before the implementation, not after. A plan that says "then write tests" at the end, rather than defining test cases as part of the design, fails this check. Look for: test cases tied to the acceptance criteria, tests for the edge cases found in check 3, and a clear sense of what "done" looks like in test form.

### 5. Vague or architectural questions
Note anywhere the plan makes an architectural decision without stating the reasoning, or leaves something ambiguous enough that two engineers could implement it differently. These should be turned into direct questions for the plan's author — asked before implementation starts, not discovered mid-build. Examples: unstated data ownership, unclear failure/rollback behavior, an unexplained choice between two viable approaches, a requirement that's open to interpretation.

## Output format

Produce the report in this structure:

```markdown
# Plan Review: [plan name/title]

## 1. Domain & System Fit
[findings]

## 2. Abstraction Level
[findings — call out over- or under-abstraction explicitly]

## 3. Edge Cases
[covered vs missing, by category]

## 4. TDD Coverage
[pass/fail + what's missing]

## 5. Open Questions
[numbered list of questions to ask before implementing — omit section if none]

## Recommendations
[numbered list — this is the section the plan-recommendation-integrator skill consumes]
1. [ARCH] ...
2. [ABSTRACTION] ...
3. [EDGE-CASE] ...
4. [TEST] ...
5. [QUESTION] ...
```

Each recommendation must:
- Start with a tag: `[ARCH]`, `[ABSTRACTION]`, `[EDGE-CASE]`, `[TEST]`, or `[QUESTION]`.
- Be a single, actionable sentence — something that can be inserted into the plan as a line item, not a paragraph of discussion.
- Reference the specific part of the plan it applies to (section name or feature name), so it can be placed correctly when merged back in.

## Notes

- If the plan is too vague to review meaningfully (e.g., no stated inputs/outputs at all), say so directly and list what's needed before a real review is possible — don't force-fill the five sections with guesses.
- Be direct. The point of this review is to catch problems before code is written, not to soften findings.