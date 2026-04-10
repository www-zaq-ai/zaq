## Plan: RBAC — Person/Team Document Permissions

**Date:** 2026-04-08
**Author:** Jad
**Status:** `completed`
**Related debt:** —
**PR(s):** —

---

## Goal

Replace ZAQ's role-based document sharing (`shared_role_ids`, `role_id` on documents/chunks) with a granular person- and team-level permission system. The new `document_permissions` table ties documents to specific persons or teams with explicit access rights (`read`, `write`, `update`, `delete`). The Ingestion UI share modal is redesigned to allow selecting people/teams via SearchableSelect. The retrieval pipeline replaces restricted chunk content with an access-denied marker so the LLM can inform users that data exists but is not shared with them. All old role-based sharing code, DB columns, and UI are removed.

---

## Context

- [ ] `docs/architecture.md`
- [ ] `docs/conventions.md`
- [ ] `docs/services/ingestion.md`
- [x] Existing code reviewed:
  - `lib/zaq/ingestion/document.ex` — Document schema (`shared_role_ids`, `role_id`, `has_many :chunks`)
  - `lib/zaq/ingestion/chunk.ex` — Chunk schema (embedding, `section_path`, `role_id`, `shared_role_ids`)
  - `lib/zaq/ingestion/ingestion.ex` — `share_file/2`, `can_access_file?`, `ingest_file/5`, `ingest_folder/5`
  - `lib/zaq/ingestion/document_processor.ex` — `query_extraction/2`, `build_query_sections/1`, `fetch_sections_with_source/1` (line 768–796), `maybe_filter_roles/2`, `similarity_search_group_by/2`
  - `lib/zaq/agent/pipeline.ex` — `run/2` (line 62–66), `do_run/2` (line 69–), `do_query_extraction/3`, `role_ids` opt
  - `lib/zaq/accounts/person.ex` — `team_ids` array field
  - `lib/zaq/accounts/team.ex` — Team schema
  - `lib/zaq_web/live/bo/ai/ingestion_live.ex` — `all_roles`, `share_modal_role_ids` assigns, `toggle_share_role`/`confirm_share` handlers
  - `lib/zaq_web/live/bo/ai/ingestion_components.ex` — `modal_share/1` (lines ~1667–1750), `shared` badge
  - `lib/zaq_web/components/searchable_select.ex` — SearchableSelect component

---

## Approach

Two-migration strategy: first add the new `document_permissions` table, then drop the old role columns. This order ensures no downtime gap in access control during implementation. `Zaq.Ingestion.Permission` is co-located with the document it protects. Partial unique indexes enforce uniqueness per person-doc and per team-doc independently. The retrieval filter runs after `fetch_sections_with_source` via a single batch query — no N+1. `maybe_filter_roles` is removed from the similarity search entirely; permission checking is the sole access control layer. When `person_id` is nil, the filter is skipped.

---

## Steps

- [x] **Step 1 — Migration (add):** Create `document_permissions` table with partial unique indexes and CHECK constraint
- [x] **Step 2 — Schema:** Add `Zaq.Ingestion.Permission` Ecto schema; add `has_many :permissions` to `Document`
- [x] **Step 3 — Context functions:** Add `list_document_permissions/1`, `set_document_permission/4`, `delete_document_permission/1`, `list_permitted_document_ids/3`; update `can_access_file?` to use Permission table; remove `share_file/2`
- [x] **Step 4 — Migration (remove):** Drop `shared_role_ids` and `role_id` from `documents` and `chunks`; remove those fields from schemas; update `ingest_file`/`ingest_folder` signatures
- [x] **Step 5a — Pipeline cleanup:** Remove `role_ids` opt from `pipeline.ex`; remove `maybe_filter_roles` call from `similarity_search_group_by`; remove `role_ids` param from `query_extraction`
- [x] **Step 5b — Pipeline — permission threading:** Load `team_ids` from person after identity plug; forward `person_id` + `team_ids` through `do_run` → `do_query_extraction` → `query_extraction`
- [x] **Step 5c — DocumentProcessor filter:** Retain `document_id` in `fetch_sections_with_source` output; add `apply_permission_filter/3`
- [x] **Step 6 — LiveView:** Remove `all_roles`, `share_modal_role_ids`, `toggle_share_role`; add new assigns + `add_permission_target`, `toggle_permission_right`, `remove_permission`, updated `confirm_share` handlers; update `ingestion_map` to include permission count instead of `shared_role_ids`
- [x] **Step 7 — UI component:** Replace `modal_share/1` with SearchableSelect-based person/team picker + access rights checkboxes + existing permissions list; update shared badge to show person/team count
- [x] **Step 8 — Tests:** Schema changeset tests, context function tests, pipeline integration tests, LiveView event tests

---

## Implementation Details

### Step 1 — Migration (add)

**File:** `priv/repo/migrations/20260408000001_create_document_permissions.exs`

Table `document_permissions`:
- `document_id` bigint NOT NULL, FK → `documents(id)` ON DELETE CASCADE
- `person_id` bigint nullable, FK → `people(id)` ON DELETE CASCADE
- `team_id` bigint nullable, FK → `teams(id)` ON DELETE CASCADE
- `access_rights` `text[]` NOT NULL DEFAULT `'{read}'`
- `timestamps(type: :utc_datetime)`

Constraints via `execute/1`:
```sql
ALTER TABLE document_permissions
  ADD CONSTRAINT check_person_or_team_present
  CHECK (person_id IS NOT NULL OR team_id IS NOT NULL);

CREATE UNIQUE INDEX uix_doc_perm_person ON document_permissions (document_id, person_id)
  WHERE person_id IS NOT NULL;

CREATE UNIQUE INDEX uix_doc_perm_team ON document_permissions (document_id, team_id)
  WHERE team_id IS NOT NULL;

CREATE INDEX idx_doc_perm_document ON document_permissions (document_id);
```

### Step 2 — Schema Module

**File:** `lib/zaq/ingestion/permission.ex`

```elixir
defmodule Zaq.Ingestion.Permission do
  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Accounts.{Person, Team}
  alias Zaq.Ingestion.Document

  schema "document_permissions" do
    belongs_to :document, Document
    belongs_to :person, Person
    belongs_to :team, Team
    field :access_rights, {:array, :string}, default: ["read"]
    timestamps(type: :utc_datetime)
  end

  @valid_rights ~w(read write update delete)

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:document_id, :person_id, :team_id, :access_rights])
    |> validate_required([:document_id, :access_rights])
    |> validate_target_present()
    |> validate_subset(:access_rights, @valid_rights)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:team_id)
    |> unique_constraint([:document_id, :person_id], name: :uix_doc_perm_person)
    |> unique_constraint([:document_id, :team_id], name: :uix_doc_perm_team)
  end

  defp validate_target_present(changeset) do
    if is_nil(get_field(changeset, :person_id)) and is_nil(get_field(changeset, :team_id)) do
      add_error(changeset, :base, "must set person_id or team_id")
    else
      changeset
    end
  end
end
```

Add `has_many :permissions, Zaq.Ingestion.Permission` to `lib/zaq/ingestion/document.ex`.

### Step 3 — Context Functions

Add to `lib/zaq/ingestion/ingestion.ex`:

**`list_document_permissions/1`**
```elixir
def list_document_permissions(document_id) do
  Permission
  |> where([p], p.document_id == ^document_id)
  |> preload([:person, :team])
  |> Repo.all()
end
```

**`set_document_permission/4`** — signature: `(document_id, :person | :team, target_id, access_rights)`
- Build attrs map with the appropriate `person_id` or `team_id`
- Get-or-insert pattern (partial unique indexes prevent `on_conflict` shortcut):
  - Attempt `Repo.get_by(Permission, document_id: doc_id, person_id: target_id)` (or team variant)
  - If found: `Repo.update(Permission.changeset(existing, %{access_rights: rights}))`
  - If nil: `Repo.insert(Permission.changeset(%Permission{}, attrs))`

**`delete_document_permission/1`**
```elixir
def delete_document_permission(permission_id) do
  case Repo.get(Permission, permission_id) do
    nil -> {:error, :not_found}
    perm -> Repo.delete(perm)
  end
end
```

**`list_permitted_document_ids/3`**
```elixir
def list_permitted_document_ids(person_id, team_ids, doc_ids) do
  from(p in Permission,
    where: p.document_id in ^doc_ids and
           (p.person_id == ^person_id or p.team_id in ^team_ids),
    select: p.document_id,
    distinct: true
  ) |> Repo.all()
end
```

**`can_access_file?/2`** — update to use Permission table:
- If no permissions exist for the document → accessible to all (public)
- If permissions exist → check `person_id` match or any `team_id` in `person.team_ids`

**Remove:** `share_file/2` entirely.

### Step 4 — Migration (remove)

**File:** `priv/repo/migrations/20260408000002_remove_role_sharing_from_docs_and_chunks.exs`

```elixir
alter table(:documents) do
  remove :role_id
  remove :shared_role_ids
end

alter table(:chunks) do
  remove :role_id
  remove :shared_role_ids
end
```

Also remove from schemas:
- `lib/zaq/ingestion/document.ex`: remove `belongs_to :role`, `field :role_id`, `field :shared_role_ids`
- `lib/zaq/ingestion/chunk.ex`: same
- `lib/zaq/ingestion/ingestion.ex`: remove `role_id` and `shared_role_ids` from `ingest_file/5` → `/3` and `ingest_folder/5` → `/3` signatures and document/chunk creation attrs

### Step 5a — Pipeline Cleanup

**`lib/zaq/ingestion/document_processor.ex`:**
- Remove `maybe_filter_roles/2` function
- Remove its call from `similarity_search_group_by` query
- Remove `role_ids` parameter from `query_extraction/2` → `/2` (drop the param, not the function) — new signature: `query_extraction(query, access_opts \\ [])`
- Remove `role_ids` param from `similarity_search_group_by`

**`lib/zaq/agent/pipeline.ex`:**
- Remove `role_ids = Keyword.get(opts, :role_ids, [])` from `do_run/2`
- Remove `role_ids` from NodeRouter call args
- Remove `:role_ids` from module `@doc` options list

### Step 5b — Pipeline — Permission Threading

In `run/2` (line ~62):
```elixir
def run(%Incoming{} = incoming, opts \\ []) do
  incoming = identity_plug_mod(opts).call(incoming, opts)
  person_id = incoming.person_id
  team_ids = case Zaq.People.get_person(person_id) do
    nil -> []
    person -> person.team_ids || []
  end
  opts = Keyword.merge(opts, [person_id: person_id, team_ids: team_ids])
  result = do_run(incoming.content, opts)
  Outgoing.from_pipeline_result(incoming, result)
end
```

In `do_query_extraction/3`, pass to NodeRouter call:
```elixir
node_router(opts).call(:ingestion, document_processor_mod(opts), :query_extraction,
  [query, [person_id: person_id, team_ids: team_ids]])
```

### Step 5c — DocumentProcessor Filter

`fetch_sections_with_source/1` (line ~791) — retain `document_id` in the final map:
```elixir
%{"content" => r.content, "source" => r.source, "distance" => dist, "document_id" => r.document_id}
```

Updated `query_extraction/2` with `access_opts`:
```elixir
def query_extraction(query, access_opts \\ []) do
  person_id = Keyword.get(access_opts, :person_id)
  team_ids  = Keyword.get(access_opts, :team_ids, [])

  with {:ok, ss} <- similarity_search_group_by(query),
       sections = build_query_sections(ss),
       {:ok, data} <- fetch_sections_with_source(sections) do
    filtered = apply_permission_filter(data, person_id, team_ids)
    {:ok, limit_to_context_window(filtered)}
  end
end
```

New private `apply_permission_filter/3`:
```elixir
defp apply_permission_filter(data, nil, _), do: data
defp apply_permission_filter(data, person_id, team_ids) do
  doc_ids = data |> Enum.map(& &1["document_id"]) |> Enum.uniq()
  permitted = Zaq.Ingestion.list_permitted_document_ids(person_id, team_ids, doc_ids)
  permitted_set = MapSet.new(permitted)

  Enum.map(data, fn chunk ->
    if MapSet.member?(permitted_set, chunk["document_id"]) do
      chunk
    else
      Map.put(chunk, "content", "You don't have access to this chunk.")
    end
  end)
end
```

> When `person_id` is nil, filter is skipped — anonymous channels see all chunks.

### Step 6 — LiveView Changes (`lib/zaq_web/live/bo/ai/ingestion_live.ex`)

**Remove:**
- `all_roles` assign
- `share_modal_role_ids` assign
- `toggle_share_role` event handler
- Old role-based `confirm_share` logic

**Add:**
```elixir
share_modal_document_id: nil,
share_modal_permissions: [],
share_modal_targets_options: [],  # combined people + teams SearchableSelect options
share_modal_pending: [],          # [%{type: :person|:team, id: int, name: str, access_rights: [str]}]
```

Preload targets in mount:
```elixir
people_opts = Accounts.list_people() |> Enum.map(&{"#{&1.full_name} (#{&1.email})", "person:#{&1.id}"})
teams_opts  = Accounts.list_teams()  |> Enum.map(&{"team: #{&1.name}", "team:#{&1.id}"})
```

Update `ingestion_map` population to include `permissions_count` (count from Permission table) instead of `shared_role_ids`.

New/updated event handlers:
- **`share_item`** — get document by source, load permissions, open `:share` modal
- **`add_permission_target`** — parse `"person:42"` or `"team:7"`, append to `share_modal_pending` (dedup guard), default `access_rights: ["read"]`
- **`toggle_permission_right`** — toggle right at index in `share_modal_pending`
- **`remove_permission`** — `Ingestion.delete_document_permission(id)`, reload permissions
- **`confirm_share`** — call `set_document_permission` for each pending entry, reload, reset pending

### Step 7 — UI Component (`lib/zaq_web/live/bo/ai/ingestion_components.ex`)

Replace `modal_share/1` layout:
1. Header: "Share: {filename}"
2. Existing permissions list: person/team name + access_rights badges + remove button (`phx-click="remove_permission"`)
3. Add target: `SearchableSelect` with combined people+team options, wired via `phx-change="add_permission_target"`
4. Pending list: name + access_rights checkboxes (`toggle_permission_right`) + remove-from-pending button
5. Footer: Cancel + "Save Permissions" (`confirm_share`)

Update `shared` badge to show person/team count from `permissions_count` instead of `shared_role_ids` length.

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Full removal of `shared_role_ids`/`role_id` | Clean break — two competing access systems add confusion and maintenance cost | 2026-04-08 |
| Two-migration strategy (add then remove) | Allows safe incremental rollout; permission system is live before old columns disappear | 2026-04-08 |
| `Permission` lives under `Zaq.Ingestion` | It describes access to a Document (ingestion concept); Person/Team are just FK references | 2026-04-08 |
| Partial unique indexes instead of composite constraint | Allows either `person_id` or `team_id` to be NULL independently while still enforcing uniqueness | 2026-04-08 |
| Get-or-insert for upsert (not `on_conflict`) | Partial indexes aren't supported as conflict targets in Ecto's `on_conflict` API | 2026-04-08 |
| Remove `role_ids` from similarity search entirely | `maybe_filter_roles` is replaced by `apply_permission_filter`; no need for two filtering layers | 2026-04-08 |
| Permission filter skipped when `person_id` is nil | Anonymous/channel-only queries have no person identity to check against | 2026-04-08 |
| `document_id` retained in `fetch_sections_with_source` output | Required for batch permission lookup; field was already queried, just dropped in the final map | 2026-04-08 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| None | — | — |

---

## Definition of Done

- [x] All steps above completed
- [x] Tests written and passing
- [x] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`
