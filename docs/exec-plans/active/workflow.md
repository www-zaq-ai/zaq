# Exec Plan — Workflow Action Contract

## Goal
Jido actions used as workflow nodes must satisfy a contract: export
`on_success/2`, `on_failure/2`, and non-empty `schema/0` + `output_schema/0`.
Enforced at DAG build time.

## Design (decided with user)
- **Hook semantics:** "Required exports only" — engine does not call the hooks;
  the contract only mandates they exist.
- **Enforcement:** behaviour `Zaq.Engine.Workflows.Action` + runtime check in
  `DagBuilder.build/2`, returning `{:error, {:contract_violation, mod, missing}}`.
- **Scope:** `action` / `agent` node types only. `condition` nodes
  (`FieldComparison`, module-backed conditions) are a distinct raise-based
  node type and are intentionally exempt.

## Steps
1. `lib/zaq/engine/workflows/action.ex` — behaviour:
   - `@callback on_success(result :: map(), context :: map()) :: :ok | {:ok, map()} | {:error, term()}`
   - `@callback on_failure(error :: term(), context :: map()) :: :ok | {:error, term()}`
   - `validate/1` → `:ok | {:error, {:contract_violation, module, [atom]}}`.
     `missing` subset of `[:on_success, :on_failure, :schema, :output_schema]`.
     `Code.ensure_loaded/1` first; empty/nil schema counts as missing.
2. DagBuilder: in the `action`/`agent` `build_node` clause only, after
   `resolve_module`, call `Action.validate/1`; propagate the error tuple.
   Condition clauses untouched.
3. Migrate `FetchEmails`, `DraftReply`, `SendReply`, `NotifyEmptyMailbox`:
   add `@behaviour` + minimal `on_success/2` (returns `{:ok, result}`) and
   `on_failure/2` (logs, returns `:ok`).
4. Tests: `action_test.exs` (validate/1 matrix), `dag_builder_test.exs`
   (contract-violation + conforming regression), assert the 4 email modules
   conform. Update `docs/services/workflows.md`. Run `mix precommit`.

## Status
- [ ] 1 behaviour + validator
- [ ] 2 DagBuilder enforcement
- [ ] 3 migrate 4 actions
- [ ] 4 tests + docs + precommit
