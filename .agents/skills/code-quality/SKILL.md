---
name: code-quality
description: Make sure produced code is of high quality and properly documented
license: MIT
compatibility: opencode
metadata:
  audience: maintainers
  workflow: github
---

## What I do

You can receive:

- A list of credo errors
- A list of lines in code with code smells

Your job:

- Apply [Write for Humans](../../../docs/code-quality.md#write-for-humans) and the [naming conventions](../../../docs/conventions.md#naming) to changed code.

- Apply the [function reuse decision](../../../docs/code-quality.md#function-reuse-decision) before adding or adapting functions, including its compatibility and risk-first, churn-second criteria.

- Before each fix, apply `docs/action-reuse.md`: inspect existing operations and record reuse / extend / new Action / local-only evidence (or not applicable with a reason). Do not resolve a smell by duplicating an Action's logic. Track missing essential composable operations as Action prerequisites; keep unrelated refactors outside this fix.

- Fix the credo errors by adapting the strategy that matches the project's code structuring requirements
- Remove code smells locally with quick wins edit
- Apply the [comment and documentation writing rules](../../../docs/documentation.md#writing-comments-and-documentation) to touched prose.

Sidetrack:

- If fixing a code smell requires an out-of-scope refactor, track the follow-up under [technical debt controls](../../../docs/code-quality.md#technical-debt-controls). Add a code comment only for a current non-obvious constraint or a tracked temporary shortcut, following the writing rules above.

DO NOT:

- Refactor code beyond the requirement to fix the code quality mistakes

## When to use me

Whenever code quality issues are identified, whether through mix tools or by indentifying errors when reading the code
