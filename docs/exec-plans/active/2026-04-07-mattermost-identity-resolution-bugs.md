# Mattermost Identity Resolution — Bug Report & Fix Plan

**Branch:** `feat/people`  
**Date:** 2026-04-07  
**Status:** Partially fixed — two known issues remain

---

## What This System Does (Context)

When a Mattermost user sends a message to ZAQ, the platform runs an identity resolution pipeline to link the sender to a **Person** record in the People directory. The goal is: by the time the AI pipeline processes the message, `incoming.person_id` is populated.

### The full call chain

```
Mattermost WebSocket event
  → Jido.Chat.Mattermost.Adapter.transform_incoming/1       (adapter normalizes raw payload)
  → Jido.Chat.Mattermost.Listener                           (dispatches to bridge)
  → Zaq.Channels.JidoChatBridge.handle_message_event/3     (builds internal Incoming struct)
  → Zaq.Agent.Pipeline.run/2
      → Zaq.People.IdentityPlug.call/2                     (resolves person_id)
          fast path:  People.match_by_channel(platform, author_id)
                      → if person is complete: record interaction, done
          slow path:  NodeRouter → Channels.Router.fetch_profile(platform, author_id)
                      → JidoChatBridge.fetch_profile(author_id, connection_details)
                      → Jido.Chat.Mattermost.Adapter.get_user(author_id, opts)
                      → GET /api/v4/users/{author_id}
                      → bridge maps response → canonical profile map
                      → People.find_or_create_from_channel(platform, profile)
      → pipeline runs with person_id set on Incoming
```

### Key files

| File | Role |
|---|---|
| `lib/zaq/channels/jido_chat_bridge.ex` | Converts Jido.Chat events to internal `Incoming`; calls `fetch_profile` |
| `lib/zaq/people/identity_plug.ex` | Fast/slow path identity resolution in the pipeline |
| `lib/zaq/people/resolver.ex` | Platform-specific normalizers (mattermost, slack, telegram, etc.) |
| `lib/zaq/accounts/people.ex` | `match_by_channel/2`, `find_or_create_from_channel/2` |
| `lib/zaq/channels/router.ex` | `fetch_profile/2` — routes to bridge, injects `:provider` into connection details |
| `jido_chat_mattermost/lib/.../adapter.ex` | `transform_incoming/1`, `get_user/2` |
| `jido_chat_mattermost/lib/.../transport/req_client.ex` | `get_user/2` → `GET /api/v4/users/{id}` |

---

## Bug 1 — Bot Processing Its Own Messages (Partially Fixed)

### What happened

When ZAQ replies in Mattermost, Mattermost fires a new WebSocket event for that post. The event has `user_id = <bot_user_id>` (e.g. `gt86t841g3duiby6pjxow7qf4o`). ZAQ was processing this as if it were a user message, running the full AI pipeline and calling `get_user(bot_id)`, creating a Person record for the bot itself.

### What was fixed

1. **`jido_chat_mattermost/adapter.ex` — `transform_incoming/1`**  
   Now explicitly builds the `author` map with `is_me: true` when `user_id` matches the configured `bot_user_id`:
   ```elixir
   bot_user_id = Application.get_env(:jido_chat_mattermost, :bot_user_id)
   author: %{
     user_id: user_id || "",
     user_name: user_id || "",
     is_me: is_binary(user_id) && user_id == bot_user_id
   }
   ```

2. **`lib/zaq/channels/jido_chat_bridge.ex` — `handle_message_event/3`**  
   Added a guard clause that drops messages from the bot before the pipeline runs:
   ```elixir
   defp handle_message_event(_config, _thread, %Chat.Incoming{author: %{is_me: true}}), do: :ok
   ```

### What still needs verification

- Confirm that `config :jido_chat_mattermost, bot_user_id: "gt86t841g3duiby6pjxow7qf4o"` is set in the ZAQ runtime config. If it is not set, `Application.get_env/2` returns `nil` and `is_me` will always be `false` — the guard will never trigger.
- The second `transform_incoming` clause (slash-command style payloads, line ~119 in adapter.ex) has the same problem — it does **not** set `is_me`. Should receive the same fix.

---

## Bug 2 — Full Name Not Populated from Mattermost Profile (Not Fixed)

### What happens

When a new Mattermost user messages ZAQ and the slow path runs, `get_user(author_id)` calls `GET /api/v4/users/{author_id}`. The Mattermost API returns:

```json
{
  "id": "barndiimztra5dg66x51dk7s9h",
  "username": "jad",
  "email": "jad@example.com",
  "first_name": "Jad",
  "last_name": "Lastname",
  "nickname": "",
  ...
}
```

The bridge's `fetch_profile/2` then maps the response:

```elixir
# lib/zaq/channels/jido_chat_bridge.ex, ~line 172
"display_name" =>
  Map.get(user, :display_name) || Map.get(user, "display_name") ||
    Map.get(user, :full_name)  || Map.get(user, "full_name"),
```

**Mattermost does not have a `display_name` or `full_name` key.** It has `first_name` + `last_name`. So `display_name` is always `nil`. This propagates through `find_or_create_from_channel` and the person is created with no name (falls back to `channel_identifier` as `full_name`, i.e. their Mattermost user ID).

### Root cause

The bridge's profile mapping is generic and doesn't know about Mattermost's `first_name`/`last_name` split. There are two places this could be fixed:

### Option A — Fix in the adapter (recommended)

`Jido.Chat.Mattermost.Adapter.get_user/2` should normalize the raw API response before returning it, composing `display_name` from `first_name` + `last_name`:

```elixir
# jido_chat_mattermost/lib/jido/chat/mattermost/adapter.ex
def get_user(user_id, opts \\ []) do
  o = FetchOptions.new(opts)
  case transport(o).get_user(user_id, FetchOptions.transport_opts(o)) do
    {:ok, user} -> {:ok, normalize_user(user)}
    error -> error
  end
end

defp normalize_user(user) do
  first = Map.get(user, "first_name", "")
  last  = Map.get(user, "last_name", "")
  display = String.trim("#{first} #{last}")

  %{
    "display_name" => (if display != "", do: display, else: Map.get(user, "nickname") || Map.get(user, "username")),
    "username"     => Map.get(user, "username"),
    "email"        => Map.get(user, "email"),
    "phone"        => Map.get(user, "phone")
  }
end
```

This keeps the bridge generic and puts Mattermost-specific field knowledge in the Mattermost adapter where it belongs.

### Option B — Fix in the bridge (less clean)

Make `fetch_profile/2` in `jido_chat_bridge.ex` provider-aware and add a Mattermost-specific clause that composes `display_name` from `first_name` + `last_name`. This works but leaks platform knowledge into the bridge.

---

## Summary of Required Changes

| # | File | Change | Status |
|---|---|---|---|
| 1 | `jido_chat_mattermost/adapter.ex` `transform_incoming/1` | Set `is_me: true` when `user_id == bot_user_id` | ✅ Done |
| 2 | `lib/zaq/channels/jido_chat_bridge.ex` | Guard `handle_message_event` against `is_me: true` | ✅ Done |
| 3 | Runtime config | Verify `config :jido_chat_mattermost, bot_user_id:` is set | ⚠️ Needs check |
| 4 | `jido_chat_mattermost/adapter.ex` second `transform_incoming` clause | Add `is_me` check for slash-command payloads | ❌ Not done |
| 5 | `jido_chat_mattermost/adapter.ex` `get_user/2` | Normalize response: compute `display_name` from `first_name + last_name` | ❌ Not done |

ReqClient.get("/api/v4/users/PASTE_MATTERMOST_USER_ID_HERE", [], url: url, token: bot_token) 

ReqClient.get("/api/v4/users/me", [], url: url, token: bot_token)

 Jido.Chat.Mattermost.Transport.ReqClient.get_user(nil,url: config.url,token: config.token)
