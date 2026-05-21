# Plan: Workflow Approval Permissions

## Goal

Replace the temporary admin-only guard in `Engine.Api`'s `:workflow` event handler with a full `Permissions.can?/4` check using the `"run"` access right. Any person or team granted `"run"` on a `Workflow` resource can approve or reject a waiting run. If no permissions are configured, only a BO admin (`nil` person_id) can approve.

**Depends on:** `human-in-the-loop.md` — the `Engine.Api` `:workflow` handler and `WorkflowApproval` schema must exist first.

## Permission Model

| Caller | `person_id` | Outcome |
|---|---|---|
| BO admin | `nil` | Always allowed (`skip_permissions: true`) |
| Person with `"run"` right on the workflow | UUID | Allowed |
| Person without `"run"` right | UUID | `{:error, :unauthorized}` |
| No permissions configured on workflow | any non-nil | `{:error, :unauthorized}` |

`Permissions.can?(person, :run, workflow)` is the check. The `"run"` right already exists in `ResourcePermission.@valid_rights` — no schema change needed.

## Scope

| Module / File | Change |
|---|---|
| `lib/zaq/engine/api.ex` | **MODIFY** — replace temporary guard with `Permissions.can?/4` |
| `docs/services/workflows.md` | **UPDATE** — permission model section |

## Pre-Planning Audit

- [x] `Permissions.can?/4` signature: `can?(person_or_nil, right, resource, opts \\ [])`. Accepts a `%Person{}` struct, not a raw `person_id`.
- [x] `Permissions.can?(nil, ...)` → `false` unless `skip_permissions: true` — confirmed in `Permissions` moduledoc.
- [x] `"run"` right exists in `ResourcePermission.@valid_rights` — no migration or schema change needed.
- [x] `WorkflowRun` has `workflow_id` — one DB load gets the parent `Workflow` for the permission check.
- [x] `People.get_person/1` or equivalent exists for loading a `%Person{}` from `person_id`.
- [x] `Engine.Api` already aliases `People` — confirmed in existing `handle_event` clauses.
- [x] The `# Temporary:` comment in `Engine.Api` (placed in `human-in-the-loop.md`) marks exactly what this plan removes.

---

## Steps

### Step 1: Full permission check in `Engine.Api` `:workflow` handler

**Depends on:** none (requires `human-in-the-loop.md` to be shipped first)

#### Functional Specifications

Replace the temporary guard in `handle_workflow_approve/4` and `handle_workflow_reject/4`:

```elixir
defp check_approval_permission(person_id, workflow) do
  cond do
    is_nil(person_id) ->
      :ok

    true ->
      person = People.get_person!(person_id)
      if Permissions.can?(person, :run, workflow) do
        :ok
      else
        {:error, :unauthorized}
      end
  end
end
```

Updated `handle_workflow_approve/4`:
1. Load `WorkflowRun` by `run_id`.
2. Load `Workflow` by `run.workflow_id`.
3. Call `check_approval_permission(person_id, workflow)` → return error if unauthorized.
4. Load pending `WorkflowApproval` for the run.
5. Call `Workflows.approve_run/5`.

Updated `handle_workflow_reject/4`: same structure.

Remove the `# Temporary:` comment after replacement.

#### Tests to add before implementation

Extend `test/zaq/engine/api_test.exs`:
- `"run.approve"` with `nil` person_id → success (admin bypass).
- `"run.approve"` with person_id that has `"run"` right on workflow → success.
- `"run.approve"` with person_id that lacks `"run"` right → `{:error, :unauthorized}`.
- `"run.approve"` with person_id when workflow has no permissions configured → `{:error, :unauthorized}`.
- `"run.reject"` with authorized person → success.
- `"run.reject"` with unauthorized person → `{:error, :unauthorized}`.

#### Branches / paths validated

- Admin (`nil`): allowed.
- Authorized person: allowed.
- Unauthorized person: rejected.
- No permissions on workflow: non-admin rejected.

#### Mocking plan

None — use real `Permissions.can?/4` with real DB rows. Insert `ResourcePermission` rows in test setup to control who has `"run"` access.

#### Documentation to update

- Remove `# Temporary:` comment from `Engine.Api`.
- `docs/services/workflows.md` — add **Approval Permissions** section under Human-in-the-Loop.

---

### Step 2: Documentation

**Depends on:** Step 1

- `docs/services/workflows.md`:
  - **Approval Permissions** section: permission model table, how to grant `"run"` right via `Permissions.grant/3`, default (no perms = admin only).
  - Security Checklist update: mark `Permissions.can?/4` wired.

---

## Security Checklist

- [x] `nil person_id` → admin bypass via `skip_permissions: true` — explicit, opt-in only.
- [x] Non-nil person_id → `Permissions.can?/4` called with real DB lookup — no implicit grants.
- [x] No permissions configured → `can?` returns `false` for all non-nil persons — unauthorized.
- [x] Negative case tested: person with no grant gets `{:error, :unauthorized}`.
- [x] `nil` person_id tested: admin gets through without a `Person` DB load.

---

## Coverage Policy

| File | Target |
|---|---|
| `engine/api.ex` | ≥ 95% |

---

## Definition of Done

- [ ] Tests written before implementation
- [ ] All tests passing (`mix test`)
- [ ] Coverage ≥ 95%
- [ ] `# Temporary:` comment removed from `Engine.Api`
- [ ] `mix precommit` passes
- [ ] `docs/services/workflows.md` updated

---

## Decisions Log

**`"run"` right used for approval — not a new `"approve"` right.**
Keeps `ResourcePermission.@valid_rights` unchanged. Approving a run is semantically equivalent to being allowed to execute the workflow.

**Permission check lives in `Engine.Api`, not in `Workflows` context.**
`Workflows` moduledoc explicitly states permission checks are the caller's responsibility. `Engine.Api` is the role boundary — the correct place to enforce who can send commands.

**Separated from `human-in-the-loop.md`.**
The permission check has its own test surface (positive + negative cases across three person states), its own DB fixture setup, and its own security review. Bundling it in the HITL plan would have made that plan harder to review and test independently.
