---
name: test-coverage-planner
description: Plan for test scenarios for uncovered code lines
license: MIT
compatibility: opencode
metadata:
  audience: maintainers
  workflow: github
---

## What I do

I receive a filename with the line numbers that are not covered by a test

- Analyse the code at the uncovered lines for the file in the current project
- Generate one detailed plan to add tests to cover the gaps for each file

## How I do it

Step 1: Read the code in the actual file for the uncovered lines
Step 2: Write a detailed plan to develop test scenarios that would cover the missing lines for the target file
Step 3: Report the plan with the test file to add/edit, the detailed scenario and branches that will be covered, the helpers that will be reused and the mocks to produce when applicable

When producing test scenarios plan:

- Favor contracted collaborator tests + thin integration tests
- Hit actual code implementation for a wider branch activation
- Build mocks/stubs using Mox when there's a need to predictably simulate an external API call
- Re-use helpers, mocks and stubs when they already exists

## When to use me

Run when a file name with a list of line numbers for uncovered lines is provided
