# Convention navigation and pitfalls

- Owners: [conventions](../../docs/conventions.md), [code quality](../../docs/code-quality.md), [Action reuse](../../docs/action-reuse.md), [testing](../../docs/testing-approach.md). Language/framework detail lives in `docs/elixir.md` and `docs/phoenix.md`.
- Read a module's moduledoc before adding responsibilities. Domain operations belong in `lib/zaq/`; BO orchestrates through the [Event/dispatch boundary](../../docs/architecture.md#noderouter--critical), not generic invoke helpers or direct remote context calls.
- Runtime test seams use `Zaq.Config.get/4` and established opts/Event carriers; avoid global env mutation or test-only production hooks. Do not add opts bags to pure functions just for symmetry.
- Tool Registry is an explicit allowlist, not the exhaustive Action catalog. Reuse discovery includes domain APIs and non-exposed Actions; reuse does not automatically authorize agent exposure.
- Nil identity is not permission. Provider/model fields are not trusted actor context. [System config](../../docs/services/system-config.md) owns secret handling; do not duplicate its checklist here.
- Real sandboxed DB and real internal modules by default; mocks at external boundaries. NodeRouter mocks must preserve Event contracts, not blanket-success every call.
- Temporary code uses the tracked comment format in [technical debt controls](../../docs/code-quality.md#technical-debt-controls), not bare TODO tags.
