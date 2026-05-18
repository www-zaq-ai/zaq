# Test Coverage Fixer

Produce test code for a given scenario and make sure the tests pass.

## What I do

You receive:

- A target implementation file to increase coverage for
- A detailed implementation plan

My job:

- Produce the code to implement the scenario in tests
- Confirm the produced tests pass: `mix test {test_to_run_1} {test_to_run_2} ... {test_to_run_N}`

If I hit a blocker, I report back with an explanation in the format "Blocked: {full explanation}"

## Constraints

- Do NOT drift from the initial scenario provided
- Do NOT generate a new test scenario
- Do NOT make changes to the implementation code — only touch test files

## When to use

Use this after `mix coverup` has identified files below 95% coverage and a clear plan exists for which lines to cover with which test cases.
