# Fix: list_knowledge_base_files ignores person-level permissions

**Issue:** #370  
**Branch:** fix/list-knowledge-tool  
**Status:** In Progress

---

## Problem

`DocumentAccess.list_accessible_documents/1` (and `count_accessible_documents/1`) use
`build_accessible_where/2` which only matches two conditions:

1. `d.tags @> ARRAY['public']` — document tagged "public"
2. `perm_cond` — person or team has an explicit permission row

**Missing:** `is_nil(p.id)` — documents with *no* permission rows at all should be
accessible by default ("public by default"). The LEFT JOIN produces a NULL `p` row for
such documents, but the WHERE clause discards them silently.

**Result (bug):** When a document has no permission rows and no "public" tag, it is
invisible to all non-admin users. The module `@moduledoc` documents this as:
> "Documents with no permission rows → public by default (accessible to all)."
…but the query does not implement it.

Additionally, the reporter states: when a document *is* shared with a specific person
and that person queries, the tool does not return it. This may be the same root cause
(e.g., the document was previously "public by default", a permission was added for
person Y, now person X — who had previously relied on the no-rows clause — is locked
out) or a secondary bug to be confirmed by the failing test run.

---

## Root cause location

| File | Location | What's wrong |
|------|----------|--------------|
| `lib/zaq/ingestion/document_access.ex` | `build_accessible_where/2` (line ~149) | Missing `is_nil(p.id)` OR branch |

---

## Fix strategy (TDD)

### Step 1 — Write failing tests

Add tests to `test/zaq/ingestion/document_access_test.exs` under the existing
`describe "list_files_with_ingestion_status/1 — permission-scoped"` and
`describe "list_accessible_documents/1"` blocks:

**New test cases (must fail before the fix):**

1. `list_accessible_documents` — authenticated person sees docs with no permission rows  
2. `list_accessible_documents` — `nil` person_id does NOT see docs with no permission rows (no-rows ≠ public for unauthenticated)  
3. `count_accessible_documents` — authenticated person counts docs with no permission rows  
4. `list_files_with_ingestion_status` — person sees no-permission-row doc tagged `ingested: true`  
5. `list_files_with_ingestion_status` — person with explicit permission sees the doc  
   (regression: existing test at line 439 should still pass after fix)

### Step 2 — Run and confirm red

```bash
mix test test/zaq/ingestion/document_access_test.exs --seed 0
```

### Step 3 — Apply fix

In `lib/zaq/ingestion/document_access.ex`, update `build_accessible_where/2`:

```elixir
# BEFORE
defp build_accessible_where(person_id, team_ids) do
  perm_cond = Permission.build_perm_join_condition(person_id, team_ids)

  dynamic(
    [doc: d, perm: p],
    fragment("? @> ARRAY['public']::varchar[]", d.tags) or
      ^perm_cond
  )
end

# AFTER — two-clause dispatch to preserve nil-person_id semantics
defp build_accessible_where(nil, team_ids) do
  perm_cond = Permission.build_perm_join_condition(nil, team_ids)

  dynamic(
    [doc: d, perm: p],
    fragment("? @> ARRAY['public']::varchar[]", d.tags) or ^perm_cond
  )
end

defp build_accessible_where(person_id, team_ids) do
  perm_cond = Permission.build_perm_join_condition(person_id, team_ids)

  dynamic(
    [doc: d, perm: p],
    is_nil(p.id) or
      fragment("? @> ARRAY['public']::varchar[]", d.tags) or
      ^perm_cond
  )
end
```

**Why two clauses?** The module doc explicitly states:
> "`nil person_id` returns only public-tagged documents and documents with
> team-matched permissions."
So "no rows = public by default" must NOT apply to unauthenticated callers.

### Step 4 — Run full suite green

```bash
mix test test/zaq/ingestion/document_access_test.exs
mix test test/zaq/agent/tools/list_knowledge_base_files_test.exs
mix precommit
```

---

## Files to modify

- `lib/zaq/ingestion/document_access.ex` — fix `build_accessible_where/2`
- `test/zaq/ingestion/document_access_test.exs` — add 4-5 new test cases

## Files NOT to modify

- `lib/zaq/agent/tools/list_knowledge_base_files.ex` — no logic change needed
- `lib/zaq/ingestion/permission.ex` — no change needed
- Migrations — no schema change needed

---

## Acceptance criteria

- [ ] All new tests written and confirmed red before fix
- [ ] All new tests green after fix
- [ ] All existing `document_access_test.exs` tests still green
- [ ] All existing `list_knowledge_base_files_test.exs` tests still green
- [ ] `mix precommit` passes
