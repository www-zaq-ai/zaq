# Exec Plan: People Identity Resolution

**Branch:** `feat/people`
**Date:** 2026-04-06
**Status:** Planning

---

## Goal

When a user sends a message on any channel (Slack, Mattermost, Teams, WhatsApp, Telegram, Discord, Email), ZAQ automatically resolves their identity against the People directory. If a match exists it links the channel to the existing person. If not, it creates a partial entry for admin review. Admins can complete, update, and merge duplicate entries via the BO UI.

---

## Flowchart Summary

```
Incoming message → Bridge → Resolver.resolve(platform, attrs)
                                    ↓
                         match_person (email → phone → channel_id)
                                    ↓
                     Found?  ──Yes──→ link channel to existing person
                       │
                      No
                       ↓
                  create partial entry (incomplete: true, role: nil)
                       ↓
                  record_interaction on PersonChannel
                       ↓
                  return {:ok, person} → msg.person_id → Pipeline
```

Admin flow:
- Review incomplete entries queue
- Merge duplicates → channels re-assigned to survivor, loser deleted
- As new channels are linked (e.g. WhatsApp adds phone), canonical fields on Person are back-filled automatically → incomplete flips to false when `full_name` + `email` + `phone` are all present

---

## Architecture Decision

The resolver is called at the **bridge level**, after `to_internal/2` converts the platform payload to `Zaq.Engine.Messages.Incoming`. The bridge attaches `person_id` to the struct before handing off to the pipeline. The pipeline never does identity work — it reads `msg.person_id`.

---

## Phases

### Phase 1 — Migrations

**File:** `priv/repo/migrations/<timestamp>_add_phone_incomplete_to_people.exs`
- `people` table: add `phone` (string, nullable), `incomplete` (boolean, default `true`, not null)

**File:** `priv/repo/migrations/<timestamp>_update_person_channels.exs`
- `person_channels` table:
  - Add `username` (string, nullable)
  - Add `display_name` (string, nullable)
  - Add `phone` (string, nullable)
  - Add `last_interaction_at` (utc_datetime, nullable)
  - Extend platform check constraint to include `telegram`, `discord`
  - Drop unique index on `(person_id, platform)`
  - Add unique index on `(person_id, platform, channel_identifier)`

---

### Phase 2 — Schema Updates

**File:** `lib/zaq/accounts/person.ex`
- Add fields: `phone`, `incomplete`
- Changeset: auto-set `incomplete: false` when `full_name` + `email` + `phone` are all present and non-empty
- `role` is independent of completeness — nil by default, editable anytime
- Admin-created entries start with `incomplete: true` until all three identity fields are filled

**File:** `lib/zaq/accounts/person_channel.ex`
- Add fields: `username`, `display_name`, `phone`, `last_interaction_at`
- Update platform validation: `~w(mattermost slack microsoft_teams whatsapp email telegram discord)`
- Update unique constraint to `[:person_id, :platform, :channel_identifier]`

---

### Phase 3 — Context Layer

**File:** `lib/zaq/accounts/people.ex`

New functions:

```elixir
# Priority: email → phone → {platform, channel_identifier}
@spec match_person(map()) :: {:ok, Person.t()} | {:error, :not_found}
def match_person(attrs)

# Core auto-flow: match → link or create partial entry
@spec find_or_create_from_channel(atom() | String.t(), map()) :: {:ok, Person.t()} | {:error, term()}
def find_or_create_from_channel(platform, attrs)

# Update last_interaction_at on the matched PersonChannel
@spec record_interaction(PersonChannel.t()) :: {:ok, PersonChannel.t()}
def record_interaction(channel)

# Re-assign all channels from loser to survivor in a transaction, then delete loser
@spec merge_persons(survivor :: Person.t(), loser :: Person.t()) :: {:ok, Person.t()} | {:error, term()}
def merge_persons(survivor, loser)

# For admin review queue
@spec list_incomplete() :: [Person.t()]
def list_incomplete()
```

Update `add_channel/1` to accept new fields (`username`, `display_name`, `phone`).
Update `create_person/1` to default `incomplete: true`.

**Canonical field back-fill rule** (applied inside `find_or_create_from_channel/2` on every message):
- If channel provides `email` and `Person.email` is nil → set `Person.email`
- If channel provides `phone` and `Person.phone` is nil → set `Person.phone`
- If channel provides `display_name` and `Person.full_name` is nil → set `Person.full_name`
- After any back-fill, re-evaluate `incomplete` flag automatically via changeset

---

### Phase 4 — Resolver Module

**File:** `lib/zaq/people/resolver.ex`

```elixir
defmodule Zaq.People.Resolver do
  @moduledoc """
  Resolves a channel sender's identity to a Person record.

  Called at the bridge level for every incoming message. Platform-specific
  normalizers map raw adapter payloads to a canonical attrs map before
  the shared match/create logic runs.
  """

  @spec resolve(platform :: atom() | String.t(), attrs :: map()) ::
          {:ok, Person.t()} | {:error, term()}
  def resolve(platform, attrs)
end
```

Responsibilities:
1. Normalize raw attrs via per-platform normalizer (maps adapter-specific field names to canonical `%{channel_id, username, display_name, email, phone}`)
2. Call `People.find_or_create_from_channel/2`
3. Call `People.record_interaction/1` on the matched/created channel
4. Return `{:ok, person}`

Per-platform normalizers (private):
- `:mattermost` / `:slack` — `channel_id: user_id`, `username: handle`, `display_name: full_name`, `email: email`
- `:microsoft_teams` — `channel_id: azure_ad_id`, `username: email`, `display_name: full_name`, `email: email`
- `:whatsapp` — `channel_id: phone`, `phone: phone` (no name or email)
- `:telegram` — `channel_id: chat_id`, `username: handle`, `display_name: first_name + last_name`
- `:discord` — `channel_id: snowflake`, `username: name#discriminator`, `display_name: nickname`
- `:email` — `channel_id: email`, `email: email`, `display_name: display_name`

---

### Phase 5 — Bridge Integration

**File:** `lib/zaq/engine/messages/incoming.ex`
- Add `person_id` field (integer | nil, default nil) to struct and typespec

**File:** `lib/zaq/channels/jido_chat_bridge.ex`
- In `handle_message_event/3`, after `msg = to_internal(incoming, thread.adapter_name)`:

```elixir
person_id =
  case Zaq.People.Resolver.resolve(msg.provider, %{
         channel_id: msg.author_id,
         username: msg.author_name,
         metadata: msg.metadata
       }) do
    {:ok, person} -> person.id
    {:error, _} -> nil
  end

msg = %{msg | person_id: person_id}
```

- `email_bridge.ex`: add resolver call stub (when `to_internal/2` is implemented)

---

### Phase 6 — Admin LiveView

**File:** `lib/zaq_web/live/bo/system/people_live.ex`

Changes:
- Add "Incomplete" tab with count badge — calls `People.list_incomplete/0`
- `PersonChannel` display: show `username`, `display_name`, `last_interaction_at`
- Merge UI:
  - "Merge" button on person card opens merge modal
  - Modal: search/select the loser person, preview what will be re-assigned
  - Confirm → calls `People.merge_persons(survivor, loser)`
  - On success: flash + refresh list

---

## File Checklist

| File | Action |
|------|--------|
| `priv/repo/migrations/..._add_phone_incomplete_to_people.exs` | Create |
| `priv/repo/migrations/..._update_person_channels.exs` | Create |
| `lib/zaq/accounts/person.ex` | Update |
| `lib/zaq/accounts/person_channel.ex` | Update |
| `lib/zaq/accounts/people.ex` | Update |
| `lib/zaq/people/resolver.ex` | Create |
| `lib/zaq/engine/messages/incoming.ex` | Update |
| `lib/zaq/channels/jido_chat_bridge.ex` | Update |
| `lib/zaq_web/live/bo/system/people_live.ex` | Update |
| `test/zaq/accounts/person_test.exs` | Create/Update |
| `test/zaq/accounts/person_channel_test.exs` | Create/Update |
| `test/zaq/accounts/people_test.exs` | Create/Update |
| `test/zaq/people/resolver_test.exs` | Create |
| `test/zaq_web/live/bo/system/people_live_test.exs` | Create/Update |
| `test/e2e/specs/people.spec.js` | Create |

---

## Open Questions

- None. All design decisions confirmed with user.

---

## Test Strategy

All implementation follows **TDD: write failing tests first, then implement to pass them**.

### Layer 1 — ExUnit (unit + integration, real DB, no mocks)

| File | Tests |
|------|-------|
| `test/zaq/accounts/person_test.exs` | Changeset: `incomplete` auto-flag logic (all 3 fields present → false; any missing → true), back-fill rules |
| `test/zaq/accounts/person_channel_test.exs` | New fields, platform validation (telegram/discord), unique constraint on (person_id, platform, channel_identifier) |
| `test/zaq/accounts/people_test.exs` | `match_person/1` priority (email → phone → channel_id), `find_or_create_from_channel/2` (new entry + match existing), `record_interaction/1`, `merge_persons/2` (channels re-assigned, loser deleted), `list_incomplete/0` |
| `test/zaq/people/resolver_test.exs` | `resolve/2` per platform (mattermost, slack, teams, whatsapp, telegram, discord, email); normalizer output shape; back-fill applied on second message |

### Layer 2 — LiveView tests (Phoenix.LiveViewTest)

| File | Tests |
|------|-------|
| `test/zaq_web/live/bo/system/people_live_test.exs` | Incomplete tab shows count + entries; merge modal opens, confirms, loser deleted; person card shows username/display_name/last_interaction_at |

### Layer 3 — Playwright e2e

| File | Journey |
|------|---------|
| `test/e2e/specs/people.spec.js` | Admin logs in → navigates to `/bo/people` → sees incomplete queue → merges two duplicate entries → entry flips complete |

---

## Quality Checks

- [ ] `mix precommit` passes
- [ ] All Layer 1 tests pass (real DB, no mocks)
- [ ] All Layer 2 LiveView tests pass
- [ ] Playwright `people.spec.js` passes locally
- [ ] Merge transaction tested: channels re-assigned, loser deleted, survivor `incomplete` re-evaluated
