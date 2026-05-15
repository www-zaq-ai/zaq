# Test Coverage Planner

Plan test scenarios for uncovered code lines.

## What I do

Given a filename and the line numbers not covered by tests:

- Analyse the code at the uncovered lines in the current project
- Generate one detailed plan to add tests to cover the gaps for each file

## How I do it

**Step 1**: Read the actual file at the uncovered lines

**Step 2**: Write a detailed plan for test scenarios that cover the missing lines

**Step 3**: Report the plan including:
- The test file to add or edit
- The detailed scenario and branches that will be covered
- Helpers that will be reused
- Mocks to produce when applicable

## Planning principles

- Favor fewer integration tests with wider branch activation
- Hit actual code implementation whenever possible
- Build mocks only when needed to predictably simulate external API calls
- Reuse existing helpers and mocks

## When to use

Run when `mix coverup` reports a file with uncovered lines. Pass the filename and missed line numbers as arguments.

Example: `/test-coverage-planner lib/zaq/ingestion/delete_service.ex — missed line numbers: 73, 90, 94`
