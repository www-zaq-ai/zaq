---
name: code-review-evaluator
description: Evaluate PR code review comments for relevancy and priority
license: MIT
compatibility: opencode
metadata:
  audience: maintainers
  workflow: github
---

## What I do

You receive a detailed code review comment including filename with line numbers, severity and problem statement. Sometimes suggestions to fix are included.

Your job:

Assess the relevancy and priority of the review provided to gate on what to do next

- Is the provided severity confirmed ?
- Should this review be included in the current PR (based on tasks tackled in this branch)
- If provided, are suggestions relevant

Produce a short report stating if the review should be tackled and if yes add any edits to it if necessary
