# Testing Approach

This document defines ZAQ's production test strategy and when property-based testing is required.

---

## Goals

- Prevent regressions in production behavior.
- Validate invariants across broad input spaces, not just examples.
- Keep tests deterministic, readable, and fast enough for `mix precommit`.

---

## Test Pyramid

1. Unit tests: primary layer for module behavior.
2. Integration tests: cross-module + DB behavior.
3. E2E tests: critical product flows only.
4. Property tests: invariant-focused tests for transformation, parsing, normalization, routing, and safety-critical logic.

Property tests complement unit/integration tests; they do not replace scenario tests.

---

## Property-Based Testing Policy

Use `ExUnitProperties`/`StreamData` when at least one condition applies:

- Input space is large or unbounded (free text, maps, nested data, lists).
- Logic enforces invariants (idempotency, monotonicity, normalization, round-trip consistency).
- Security boundaries depend on defaults/guards (`nil` identity, permission filtering, prompt safety checks).
- Code paths are branch-heavy and example tests would miss edge combinations.

### Required for Agent Domain

When touching `lib/zaq/agent/`, add or update property tests for applicable invariants, especially:

- Permission/scope safety invariants (nil identity must not grant elevated access).
- Normalization invariants (provider/query/citation/filter normalization is stable and safe).
- Output-shape invariants (result maps/structs preserve required keys and types).
- Runtime-id/adapter invariants (deterministic mappings, no malformed IDs accepted).

If property tests are not added for an applicable change, document why in the PR.

---

## Property Test Design Rules

- Define the invariant first in plain language.
- Keep generators domain-constrained (avoid unrealistic garbage when it adds no value).
- Use bounded sizes to keep runtime predictable.
- Prefer multiple focused properties over one mega-property.
- Use fixed seeds when investigating failures; commit minimal reproducer tests for confirmed bugs.
- Avoid flakiness: no sleeps, no timing assumptions, no external network.

---

## Suggested Patterns

- Idempotency: `normalize(normalize(x)) == normalize(x)`.
- Round-trip: `decode(encode(x)) == x` (or defined canonical form).
- Monotonic constraints: confidence/score/rank constraints remain within valid bounds.
- Safety defaults: absent optional auth context never widens access.
- Ordering guarantees: sorted outputs remain sorted for any valid input set.

---

## CI and Review Expectations

- `mix precommit` must pass.
- `mix test` must pass.
- New development still targets >=90% coverage in changed scope.
- For invariant-heavy changes, reviewers should expect at least one property test.

---

## Minimal Template

```elixir
defmodule Zaq.SomeModulePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "normalization is idempotent" do
    check all input <- some_generator() do
      assert normalize(normalize(input)) == normalize(input)
    end
  end
end
```

