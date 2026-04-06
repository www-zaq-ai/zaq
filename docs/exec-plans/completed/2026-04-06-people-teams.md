# Execution Plan: People Teams

**Date:** 2026-04-06
**Author:** Jad
**Status:** `completed`
**Related debt:** —
**PR(s):** —

---

## Goal

Add a Teams feature to the People directory. A Team is a label (name + description). A person can belong to many teams. Teams are stored as a `team_ids` integer array on the `people` table — no join table. Done looks like: admins can create/edit/delete teams and assign any number of teams to a person from the People LiveView.

---

## Context

- Existing code reviewed:
  - `lib/zaq/accounts/person.ex` — Person schema (`people` table)
  - `lib/zaq/accounts/person_channel.ex` — PersonChannel schema (`channels` table)
  - `lib/zaq/accounts/people.ex` — People context
  - `lib/zaq_web/live/bo/system/people_live.ex` — LiveView
  - `lib/zaq_web/live/bo/system/people_live.html.heex` — template
  - `priv/repo/migrations/20260305073411_create_people.exs` — people migration

---

## Approach

A `Team` is a standalone entity (`name`, `description`) in its own `teams` table. A `Person` holds a `team_ids` field of type `{:array, :integer}` — a PostgreSQL integer array column on `people`. No join table is needed.

Trade-off acknowledged: no DB-level FK constraint on array elements (referential integrity is enforced in the context layer). In exchange, assignment is a simple array update with no extra schema or migration for the join.

Since the `create_people` migration is on the current branch (not yet on `main`), we can create the `teams` migration with an earlier timestamp and add `team_ids` to the `create_people` migration directly.

---

## Steps

- [x] **Step 1: Migrations**
  - `20260305073400_create_teams.exs` — creates `teams` table (`name` unique not null, `description`, timestamps) using `create_if_not_exists`
  - `20260406000000_add_team_ids_to_people.exs` — adds `team_ids {:array, :integer} default: []` to `people` using `add_if_not_exists` (separate migration because `create_people` uses `create_if_not_exists` which skips columns on existing tables)
  - `20260406000001_add_description_to_teams.exs` — adds `description` to `teams` using `add_if_not_exists` (same reason — `teams` table already existed without description column)

- [x] **Step 2: Schema — `Zaq.Accounts.Team`**
  - New file `lib/zaq/accounts/team.ex`
    - Fields: `name` (required, unique), `description` (optional)
    - `changeset/2` and `update_changeset/2`
  - Update `lib/zaq/accounts/person.ex`
    - Add `field :team_ids, {:array, :integer}, default: []`

- [x] **Step 3: Context — extend `People` with Team CRUD + assignment**
  - Add to `lib/zaq/accounts/people.ex`:
    - `list_teams/0`
    - `get_team!/1`
    - `create_team/1`
    - `update_team/2`
    - `delete_team/1` — also removes the team's id from all `team_ids` arrays (via `Repo.update_all` with `array_remove`)
    - `assign_team(person, team_id)` — appends id to array if not present
    - `unassign_team(person, team_id)` — removes id from array
  - Update `list_people/0` and `get_person_with_channels!/1` to also fetch resolved teams:
    - After loading people, do a single `list_teams()` lookup and resolve team structs from `team_ids` in-memory (avoids N+1, no preload needed since there's no association)

- [x] **Step 4: LiveView — Teams CRUD panel + person assignment**

  **Assigns to add to `mount/3`:**
  ```
  :teams      — all Team structs (used in list and for resolving badges)
  :active_tab — :people | :teams
  ```

  **New events:**
  - `switch_tab` (`"people"` | `"teams"`) — toggles left panel
  - `open_modal` with `entity: "team"` (action: `"new"` | `"edit"`) — reuses existing modal pattern
  - `validate` with `"team"` params key
  - `save` with `"team"` params key
  - `confirm_delete` / `delete` for `entity: "team"`
  - `toggle_team` — fires from person detail panel with `team_id`; calls `assign_team` or `unassign_team` based on whether id is already in `team_ids`

  **Template changes:**
  - Left panel: tab bar `People | Teams` above the list
  - `active_tab == :teams`: teams list in the same card style as people
  - Person detail info grid: add a "Teams" section below the 3-col grid
    - Shows assigned team name badges
    - Inline team picker: a list of all teams with toggle checkboxes/buttons to add or remove
  - Modal: team form with `name` input + `description` textarea, reusing existing overlay

- [x] **Step 5: Tests**
  - Context tests: CRUD for teams, `assign_team`, `unassign_team`, `delete_team` clears from all people, resolve teams from `team_ids`
  - LiveView tests: create/edit/delete team, toggle team on person, tab switching

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| `team_ids` array on `people` instead of join table | Simpler — no join schema, no join migration; assignment is an array update | 2026-04-06 |
| No DB-level FK on array elements | PostgreSQL doesn't support FK constraints on array values; enforced in context layer | 2026-04-06 |
| `delete_team` uses `array_remove` via `Repo.update_all` | Keeps referential integrity without a join table | 2026-04-06 |
| Resolve team structs in-memory after list_people | Single `list_teams()` + in-memory map lookup avoids N+1 with no Ecto association | 2026-04-06 |
| Separate `add_team_ids_to_people` and `add_description_to_teams` migrations | `create_if_not_exists` skips columns on pre-existing tables; separate `add_if_not_exists` migrations handle both fresh and existing DBs | 2026-04-06 |
| Teams managed inside `PeopleLive` (no new route) | Teams only exist in the context of people | 2026-04-06 |
| `toggle_team` event (immediate, no save button) | Label UX — toggle on/off feels natural | 2026-04-06 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| — | — | — |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing
- [ ] `mix precommit` passes
- [ ] Plan moved to `docs/exec-plans/completed/`
