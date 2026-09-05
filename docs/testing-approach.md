# ZAQ Testing Handbook

This document is the authoritative source for testing policy, design, and
implementation across ZAQ. Domain documentation may add constraints, but must not
duplicate or contradict this handbook.

## Objectives

ZAQ tests must:

- protect production behavior and security boundaries;
- execute the real implementation through stable public contracts;
- remain deterministic, isolated, readable, and fast;
- fail with enough context to diagnose the regression;
- cover meaningful branches and invariants, not merely increase line coverage.

Prefer the smallest test that provides production-relevant confidence. Tests should
assert observable outcomes, not the internal sequence used to produce them.

## Choosing a Test Level

| Test level | Use when | Avoid when |
| --- | --- | --- |
| Unit | One module's public contract can be exercised with deterministic inputs and collaborators | The behavior depends on an Ecto query, supervision, routing, or another real boundary |
| Collaborator contract | A behavior-backed boundary must be exercised with controlled responses | Mocking an internal module would bypass the implementation under test |
| Integration | Confidence depends on multiple real modules, the database, processes, events, or routing working together | The same behavior can be proven cheaply through one public module |
| Property | A stable invariant must hold over a broad or combinatorial input space | The requirement is a single concrete workflow or side effect |
| E2E | A critical user journey must be proven through the deployed interface | Unit or integration tests already provide equivalent confidence |

Use contracted collaborator tests plus thin integration tests by default. A thin
integration test crosses only the boundaries necessary to prove the behavior; it is
not a broad test of unrelated subsystems.

Property tests complement example-based tests. E2E guidance, fixtures, and commands
live in `docs/e2e-testing.md`.

## Selecting Scenarios

Start from the public contract and enumerate only applicable scenarios:

- successful behavior and meaningful output variants;
- validation boundaries, empty values, malformed input, and invalid transitions;
- collaborator errors, timeouts, retries, and exhausted retries;
- authorization and scope defaults, especially missing identity;
- duplicate, reordered, or concurrent events where ordering or idempotency matters;
- persistence success, rollback, uniqueness, and not-found behavior;
- regression cases that reproduce a confirmed defect.

Every regression fix must include a test that fails for the original defect. Do not
create Cartesian-product test suites when one property or boundary example proves the
same rule more clearly.

## Assertions and Observable Behavior

Assert what a caller or collaborating boundary can observe:

- returned values and errors;
- persisted records and transaction outcomes;
- emitted `%Zaq.Event{}` values and messages;
- process lifecycle or state exposed through a supported interface;
- external requests made through a behavior contract;
- rendered UI and user-visible effects.

Prefer exact assertions for required fields and important values. Avoid assertions
that merely confirm a broad shape when incorrect content would still pass. Include
identifiers and relevant values in assertion patterns so failures remain diagnostic.

Do not assert private function calls, incidental message order, internal state layout,
or query count unless that detail is itself a required contract. Never copy production
logic into a test to calculate the expected result; use independently known examples or
invariants.

## Collaborators and Mox

Exercise real internal modules whenever practical. Introduce a controlled collaborator
only at a genuine boundary such as HTTP, email, storage, an LLM provider, time, or
another nondeterministic service.

Use Mox when the boundary has a behavior and the test must deterministically control or
verify its response:

- define mocks once under `test/support/`;
- use `setup :verify_on_exit!` so unmet expectations fail the owning test;
- prefer process-private expectations and stubs so tests remain `async: true`;
- use `Mox.allow/3` when a known child process invokes the mock;
- use global Mox mode only when ownership cannot be expressed; isolate those tests in an
  `async: false` module;
- use `expect/4` when the call is part of the behavior under test and `stub/3` when it is
  incidental setup shared by multiple calls;
- verify contract-relevant arguments rather than matching every incidental field.

For NodeRouter, never blanket-stub `Zaq.NodeRouterMock`. Stub `dispatch/1` per test with
a `%Zaq.Event{}` pattern, or assert the exact event when dispatch is the behavior under
test.

Prefer a small deterministic fake over many Mox expectations when stateful behavior is
the contract and call order is not. Never call external networks from automated tests.

## Dependency Injection and Global State

Global state includes application environment, globally registered processes, global
Mox mode, persistent terms, shared ETS tables, filesystem paths, and other resources
visible across test processes. Avoid it as a test seam.

Follow the production dependency-boundary rules in `docs/conventions.md`. Test coverage
should use seams designed with the implementation, not trigger a later refactor or the
addition of test-only hooks.

When production code reads runtime configuration:

- read it through `Zaq.Config.get/4`;
- let the public call accept an opts keyword list;
- pass `config: TestConfig` for direct calls;
- pass the override through `%Zaq.Event{opts: [config: TestConfig]}` or the event helper's
  opts argument for routed calls;
- thread opts into spawned processes that need the same override.

Tests should override dependencies at the public boundary. Internal pure functions
should receive resolved modules or values and should not need their own opts parameter.

Only mutate application environment when injection is impossible and the global
behavior itself is under test. Put those scenarios in a dedicated `async: false` module,
capture the original value, and restore it with `on_exit/1`.

Do not add public functions, test-only branches, compile-time test flags, test callbacks,
or test-library calls to production modules solely to make them testable. Add a
production-meaningful seam or test through the public contract instead. Test-only
modules and Ecto SQL Sandbox calls belong under `test/`, never in production code.

## Determinism

Control every nondeterministic input that affects the assertion:

- inject clocks or pass explicit timestamps when time is part of the behavior;
- inject or seed randomness and assert invariant properties rather than random values;
- use unique factories or identifiers for globally constrained records;
- isolate filesystem work in per-test temporary directories and remove it in `on_exit/1`;
- avoid fixed process names unless the name is the contract;
- do not depend on local environment variables, test execution order, or data left by
  another test.

Freeze only the inputs relevant to the scenario. Avoid brittle snapshots of large
structures when focused assertions express the contract better.

## Processes, Concurrency, and Synchronization

Start processes with `start_supervised!/1` so ExUnit cleans them up. Monitor processes
when termination is part of the behavior:

```elixir
pid = start_supervised!({Worker, opts})
ref = Process.monitor(pid)

assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
```

Synchronize on observable events rather than elapsed time:

- use `assert_receive` for completion, emitted events, and state-change notifications;
- use `Process.monitor/1` and assert the `:DOWN` message for termination;
- use `_ = :sys.get_state(pid)` as a synchronization barrier after messages sent to a
  GenServer when its state need not be asserted;
- subscribe to the relevant PubSub topic before triggering the action, then assert the
  published event;
- use `Task.await/2` when the task handle is part of the production API;
- query persistence only after receiving the production completion signal.

Do not use `Process.sleep/1`, `:timer.sleep/1`, arbitrary delays, repeated polling, or
`Process.alive?/1` to coordinate tests. Timeouts on `assert_receive`, `Task.await/2`, and
similar calls are failure bounds, not delays; keep them as short as reliability permits.

A sleep is allowed only when elapsed wall-clock time is itself the behavior under test
and no injectable clock or timer seam exists. Such a test must be `async: false`, use the
minimum duration, and include a comment explaining why event-based synchronization is
not possible.

Do not add test-only notifications to production code. Prefer an existing production
boundary or introduce an event that has production meaning.

## Async Test Isolation

Default to `use ExUnit.Case, async: true`. Keep async-safe scenarios separate from tests
that mutate global state so one exceptional test does not serialize an entire unrelated
suite.

Use `async: false` when a test mutates or relies on shared VM state, including:

- application environment without per-call injection;
- global Mox mode;
- fixed global process names;
- shared filesystem paths, ETS tables, or persistent terms;
- SQL Sandbox shared mode.

An `async: false` test is not automatically isolated from async modules. It must still
restore global state and avoid keys or resources concurrently used by async tests.

## Database Tests

Use `Zaq.DataCase` and Ecto SQL Sandbox for database isolation. Build the minimum data
needed for the behavior and assert persisted outcomes through the public context where
possible.

When a process started by the test needs database access, start it first and allow its
PID from test setup:

```elixir
pid = start_supervised!({Worker, opts})
Ecto.Adapters.SQL.Sandbox.allow(Zaq.Repo, self(), pid)
```

Never call SQL Sandbox from a production module or from `init/1`. Use shared sandbox mode
only in `async: false` tests where explicit ownership cannot model the process tree.

Prefer factories or builders that produce valid records, then override only fields
relevant to the scenario. Use changesets or public contexts when their behavior matters;
insert directly only when the test is intentionally arranging unrelated persisted state.
Use unique values for database constraints so async tests cannot collide.

## Test Data and Support Code

Before adding support code, inspect `test/support/` and nearby tests for existing:

- factories and builders;
- fixtures and data-case helpers;
- event and NodeRouter helpers;
- Mox definitions, fakes, and stubs;
- authentication and connection setup.

Reuse helpers when they preserve the scenario's intent. Keep important inputs visible in
the test instead of hiding them behind a generic setup function. Extract a helper after
meaningful duplication appears, not in anticipation of reuse.

Keep fixtures minimal and deterministic. Prefer builders with explicit overrides over
large shared fixtures. Avoid setup that creates data unused by most tests in the module.

## Property-Based Testing

Use `ExUnitProperties` and `StreamData` when at least one condition applies:

- the valid input space is large or unbounded;
- logic enforces idempotency, monotonicity, normalization, round-trip consistency, or
  ordering;
- permission or security boundaries depend on defaults and guards;
- branch combinations are impractical to cover reliably with examples;
- mappings or state transitions must reject all malformed values.

Common ZAQ properties include:

- `normalize(normalize(value)) == normalize(value)`;
- `decode(encode(value))` equals the original value or its documented canonical form;
- absent identity never widens permissions;
- scores, ranks, and counters remain within valid bounds;
- required result keys and types are preserved;
- deterministic mappings never emit malformed IDs or invalid transitions.

Define the invariant in plain language before writing the property. Keep generators
domain-constrained and bounded. Prefer several focused properties over one mega-property.
Do not generate unrealistic garbage unless rejection of arbitrary input is the contract.

Property tests do not replace concrete regression examples or integration tests. Use a
fixed seed while investigating a failure and commit a minimal example test for a
confirmed defect. When an applicable change has no property test, document why in the
PR.

## Anti-Patterns

Do not:

- mock the module under test or every internal collaborator;
- reproduce the implementation in test assertions;
- expose private internals solely for testing;
- depend on sleeps, polling, execution order, or another test's data;
- blanket-stub a router or collaborator so unexpected calls silently pass;
- assert only that a result is non-nil or has a broad shape;
- test framework or library behavior ZAQ does not own;
- create oversized setup blocks or fixtures unrelated to most scenarios;
- use line coverage as a substitute for branch, error, and invariant coverage;
- add test-specific behavior to production code.

## Coverage and Validation

New development and every touched file target at least 95% coverage. Coverage is a
guardrail, not the objective: a test suite with high line coverage but weak assertions,
missing branches, or bypassed implementation is insufficient.

Review coverage alongside:

- public behaviors and meaningful branches exercised;
- failures and boundary conditions covered;
- applicable invariants tested;
- production code actually executed;
- tests remaining deterministic and async-safe.

If 95% is not feasible, document the exact uncovered behavior, reason, risk, and
follow-up plan in the PR.

After any code or documentation task, run `mix q` and fix every failure. Do not replace
it with ad-hoc checks. Run narrower tests during development for feedback, but they do
not replace the final quality gate.

## Review Checklist

- The chosen test level is the smallest one that provides production-relevant confidence.
- Tests execute real production paths and assert observable behavior.
- Success, failure, boundary, security, and concurrency scenarios are covered where applicable.
- Mox is used only at behavior-backed boundaries and expectations are process-safe.
- Runtime dependencies use `Zaq.Config` or another explicit production seam.
- Async tests do not mutate shared state; unavoidable global-state tests are isolated and restore it.
- Processes are supervised and synchronization relies on events, monitors, or barriers, not sleeps.
- Database ownership and child-process access are explicit.
- Existing support helpers are reused without hiding scenario intent.
- Applicable invariants have focused property tests.
- No test concerns leak into production code.
- Coverage is at least 95%, or the exception is documented.
- `mix q` passes.
