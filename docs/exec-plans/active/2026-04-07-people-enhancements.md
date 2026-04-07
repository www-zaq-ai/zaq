# Exec Plan: People Enhancements

**Branch:** `feat/people`
**Date:** 2026-04-07
**Status:** Implemented
**Supersedes:** `2026-04-06-people-identity-resolution.md` (partially — architectural changes only)

---

## Goal

Five targeted improvements to the People identity resolution feature:

1. Remove the "Incomplete" tab from the BO UI
2. Allow creating a new team inline from the team assignment searchable input
3. Move identity resolution out of the bridge and into a pipeline plug
4. Profile enrichment via `Channels.Router` → bridge → platform API, inline before identity resolution
5. Filters on the People tab (name, email, phone, complete status, teams)

---

## Improvement 1 — Remove Incomplete Tab from UI

**Why:** The incomplete queue overwhelms admins. Completeness is signaled by the existing `incomplete` badge on person cards in the People tab.

**Files:**
- `lib/zaq_web/live/bo/system/people_live.ex`
  - Remove `:incomplete_people` assign from `mount/3`
  - Remove `People.list_incomplete()` call from mount
  - Remove `"switch_tab"` handling for `"incomplete"` tab
  - Remove all assigns referencing `:incomplete` tab state
- `lib/zaq_web/live/bo/system/people_live.html.heex`
  - Remove the Incomplete tab button and its rendered content block

**Keep:**
- `People.list_incomplete/0` context function — will be used by RBAC enforcement later
- The `incomplete` badge rendering on person cards in the People tab

---

## Improvement 2 — Create Team Inline from Searchable Input

**Why:** Admins should not need to navigate to the Teams tab to create a team before assigning it. If the typed team name doesn't exist, they should be able to create and assign in one click.

### UI behavior

When the team searchable input has a query with no matching result, render an "Add [query]" button below the empty results list. Clicking it:
1. Creates the team
2. Assigns it to the current person
3. Refreshes the teams list and person's team assignments

### New event handler

```elixir
# lib/zaq_web/live/bo/system/people_live.ex
def handle_event("create_and_assign_team", %{"name" => name}, socket) do
  person = socket.assigns.selected_person

  with {:ok, team} <- People.create_team(%{name: name}),
       {:ok, _} <- People.add_team_to_person(person, team) do
    updated_person = People.get_person_with_channels!(person.id)

    {:noreply,
     socket
     |> assign(:teams, People.list_teams())
     |> assign(:selected_person, updated_person)
     |> put_flash(:info, "Team \"#{name}\" created and assigned.")}
  else
    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Failed to create team.")}
  end
end
```

### Template change

In the team assignment section of the person detail panel, after the searchable select results list, add:

```heex
<%= if @team_search != "" and @team_search_results == [] do %>
  <button phx-click="create_and_assign_team" phx-value-name={@team_search}>
    Add "<%= @team_search %>"
  </button>
<% end %>
```

**New assigns needed:**
- `:team_search` — current search string in team input (already exists or needs adding)
- `:team_search_results` — filtered team list for the input

---

## Improvement 3 — Move Identity Resolution into Pipeline Plug

**Why:** The bridge (`JidoChatBridge`) currently calls `Resolver.resolve/2` directly inside `handle_message_event/3`. The bridge must not do People directory work — it violates separation of concerns. The pipeline is the right place: it receives `%Incoming{}` and enriches it.

### New module: `Zaq.People.IdentityPlug`

**File:** `lib/zaq/people/identity_plug.ex`

```elixir
defmodule Zaq.People.IdentityPlug do
  @moduledoc """
  Pipeline plug that resolves sender identity and enriches %Incoming{} with person_id.

  Fast path (known user): match by (platform, channel_identifier) via DB only.
  Slow path (first message or incomplete person): fetch profile from platform API
  via Channels.Router, then match or create.

  Always returns %Incoming{} — person_id is nil on any error so the pipeline
  continues without identity context.
  """

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Accounts.People
  alias Zaq.People.Resolver

  @spec call(Incoming.t(), keyword()) :: Incoming.t()
  def call(%Incoming{} = incoming, opts \\ []) do
    case resolve_person(incoming, opts) do
      {:ok, person} -> %{incoming | person_id: person.id}
      {:error, _}   -> incoming
    end
  end
```

### Resolution logic (inside `IdentityPlug`)

```
1. Normalize raw attrs via Resolver.normalize(platform, incoming)
   → %{channel_identifier:, username:, display_name:, email: nil, phone: nil}

2. Fast path: People.match_by_channel(platform, channel_identifier)
   → person found AND complete? → record_interaction → return {:ok, person}

3. Slow path (no match OR person incomplete):
   a. NodeRouter.call(:channels, Zaq.Channels.Router, :fetch_profile,
        [platform, author_id])
      → {:ok, %{email:, display_name:, username:, phone:}} | {:error, _}
   b. Merge fetched profile into normalized attrs
   c. People.find_or_create_from_channel(platform, enriched_attrs)
      → back-fills canonical fields on Person, re-evaluates incomplete flag
   d. People.record_interaction(channel)
   e. return {:ok, person}

4. On any error → {:error, reason} (caller sets person_id: nil, pipeline continues)
```

### Pipeline integration

**File:** `lib/zaq/agent/pipeline.ex` — update `run/2`:

```elixir
def run(%Incoming{} = incoming, opts \\ []) do
  incoming = identity_plug(opts).call(incoming, opts)   # ← new
  result = do_run(incoming.content, opts)
  Outgoing.from_pipeline_result(incoming, result)
end
```

Add configurable module override for testability:
```elixir
defp identity_plug(opts) do
  Keyword.get(opts, :identity_plug,
    Application.get_env(:zaq, :pipeline_identity_plug_module, Zaq.People.IdentityPlug))
end
```

### Bridge cleanup

**File:** `lib/zaq/channels/jido_chat_bridge.ex` — `handle_message_event/3`:
- Remove the `Resolver.resolve(...)` block (lines 283–293)
- Remove `alias Zaq.People.Resolver`
- `msg` is passed to `run_pipeline` without a `person_id` pre-set; the plug handles it

### Resolver module refactor

**File:** `lib/zaq/people/resolver.ex`
- `resolve/2` becomes `normalize/2` — pure per-platform field mapping, no DB calls
- Returns canonical `%{channel_identifier:, username:, display_name:, email:, phone:}` only
- All match/create logic moves to `IdentityPlug` and `People` context

---

## Improvement 4 — Profile Enrichment via Channels.Router

**Why:** To correctly resolve identity (especially for RBAC), we need the person's email from the platform. Mattermost/Slack messages carry `author_id` but not email. Fetching the platform profile enables email-based matching against existing Person records.

**When it runs:** Inside `IdentityPlug` slow path — after a channel-id lookup fails or when the matched person is incomplete. It runs **inline/synchronously** because the result affects identity resolution, which affects RBAC. First message from a new user is slower; all subsequent messages hit the fast path.

### `Channels.Router.fetch_profile/2`

**File:** `lib/zaq/channels/router.ex` — add:

```elixir
@doc """
Fetches the platform profile for a given author_id.

Returns {:ok, %{email:, display_name:, username:, phone:}} or {:error, reason}.
Called by IdentityPlug for first-time or incomplete person resolution.
"""
@spec fetch_profile(atom() | String.t(), String.t()) ::
        {:ok, map()} | {:error, term()}
def fetch_profile(provider, author_id) when is_binary(author_id) do
  with {:ok, bridge} <- resolve_bridge(provider),
       true <- function_exported?(bridge, :fetch_profile, 2) || {:error, :unsupported},
       connection_details <- fetch_connection_details(provider) do
    bridge.fetch_profile(author_id, connection_details)
  end
end
```

### `JidoChatBridge.fetch_profile/2`

**File:** `lib/zaq/channels/jido_chat_bridge.ex` — add:

```elixir
@doc "Fetches a user's canonical profile from the platform API."
@spec fetch_profile(String.t(), map()) :: {:ok, map()} | {:error, term()}
def fetch_profile(author_id, %{url: url, token: token}) do
  # delegates to the jido_chat adapter's user profile fetch
  # returns %{email:, display_name:, username:, phone:} normalized
end
```

### Skip condition (fast path guard)

In `IdentityPlug`, only call `Router.fetch_profile` when:
- No `PersonChannel` record exists for `{platform, channel_identifier}`, **OR**
- The matched `Person` has `incomplete: true`

Once a person has `email` + `full_name` + `phone`, `incomplete` flips to `false` via the changeset and subsequent messages never hit the slow path.

---

## Improvement 5 — Filters on People Tab

**Why:** As the People directory grows, admins need to find people quickly by name, email, phone, completeness, or team.

### New assigns

```elixir
# mount/3 additions
|> assign(:filters, %{name: "", email: "", phone: "", complete: :all, team_id: nil})
|> assign(:filtered_people, People.list_people())
```

### Filter event handler

```elixir
def handle_event("filter_people", params, socket) do
  filters = %{
    name:     Map.get(params, "name", ""),
    email:    Map.get(params, "email", ""),
    phone:    Map.get(params, "phone", ""),
    complete: parse_complete_filter(Map.get(params, "complete", "all")),
    team_id:  parse_id(Map.get(params, "team_id"))
  }

  {:noreply,
   socket
   |> assign(:filters, filters)
   |> assign(:filtered_people, People.filter_people(filters))}
end
```

### Context function

**File:** `lib/zaq/accounts/people.ex` — add:

```elixir
@spec filter_people(map()) :: [Person.t()]
def filter_people(filters) do
  # builds a dynamic Ecto query from non-empty filter fields
  # name/email/phone: case-insensitive ilike
  # complete: true | false | :all
  # team_id: join on person_teams
end
```

### Template changes

Add a filter bar above the people list with:
- Text input for name (debounced)
- Text input for email (debounced)
- Text input for phone (debounced)
- Select for complete status: All / Complete / Incomplete
- Select for team: All / [team names]

Use `phx-change="filter_people"` on a wrapping form. Use `phx-debounce="300"` on text inputs.

---

## File Checklist

| File | Action |
|------|--------|
| `lib/zaq/people/identity_plug.ex` | Create |
| `lib/zaq/people/resolver.ex` | Refactor (`resolve/2` → `normalize/2`) |
| `lib/zaq/agent/pipeline.ex` | Add identity plug call in `run/2` |
| `lib/zaq/channels/jido_chat_bridge.ex` | Remove resolver call; add `fetch_profile/2` |
| `lib/zaq/channels/router.ex` | Add `fetch_profile/2` |
| `lib/zaq/accounts/people.ex` | Add `filter_people/1`, `match_by_channel/2` |
| `lib/zaq_web/live/bo/system/people_live.ex` | Remove incomplete tab; add create_and_assign_team; add filters |
| `lib/zaq_web/live/bo/system/people_live.html.heex` | Remove incomplete tab UI; add inline team create; add filter bar |
| `test/zaq/people/identity_plug_test.exs` | Create |
| `test/zaq/people/resolver_test.exs` | Update (normalize/2 only) |
| `test/zaq/accounts/people_test.exs` | Add filter_people/1, match_by_channel/2 tests |
| `test/zaq/channels/router_test.exs` | Add fetch_profile/2 test |
| `test/zaq_web/live/bo/system/people_live_test.exs` | Update (no incomplete tab; filter tests; inline team create) |

---

## Flow Diagrams

### Identity Resolution (new)

```
Incoming message
      ↓
Bridge.handle_message_event
      ↓
Pipeline.run(%Incoming{person_id: nil})
      ↓
IdentityPlug.call(incoming)
      ↓
  Resolver.normalize(platform, incoming)
      ↓
  People.match_by_channel(platform, channel_id)
      ├─ found + complete ──→ record_interaction → person_id set → fast exit
      └─ not found OR incomplete
            ↓
        NodeRouter.call(:channels, Router, :fetch_profile, [platform, author_id])
            ↓
        Router → bridge → platform API → %{email, display_name, phone}
            ↓
        People.find_or_create_from_channel(platform, enriched_attrs)
            ↓
        record_interaction → person_id set
      ↓
%Incoming{person_id: person.id}
      ↓
Pipeline.do_run(content, opts)
```

### Subsequent messages (fast path)

```
Incoming message
      ↓
IdentityPlug → People.match_by_channel → found + complete → person_id set
      ↓ (no Router/bridge/API call)
Pipeline.do_run
```

---

## Open Questions

- None. All design decisions confirmed with user.

---

## Quality Checks

- [ ] `mix precommit` passes
- [ ] Bridge no longer imports or calls `Resolver`
- [ ] `IdentityPlug` is overridable via app env (testability)
- [ ] Fast path confirmed: second message from same user never calls `Router.fetch_profile`
- [ ] Filter query uses DB-side ilike (not in-memory Enum.filter)
- [ ] Inline team create assigns team immediately without page reload 