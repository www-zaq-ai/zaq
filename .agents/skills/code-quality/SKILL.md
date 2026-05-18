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

- Fix the credo errors by adapting the strategy that matches the project's code structuring requirements
- Remove code smells locally with quick wins edit

Sidetrack:

- If fixing a code smell would require a major refactor, leave it as-is and put a short comment above the code smell to indicate what refactor is needed

DO NOT:

- Refactor code beyond the requirement to fix the code quality mistakes

## When to use me

Whenever code quality issues are identified, whether through mix tools or by indentifying errors when reading the code
