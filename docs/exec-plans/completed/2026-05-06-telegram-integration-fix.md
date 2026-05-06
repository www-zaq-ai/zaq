# Execution Plan: Telegram Integration Fix

**Date:** 2026-05-06
**Author:** Jad
**Status:** `completed`
**Related debt:** n/a
**PR(s):** fix/telegram

---

## Goal

Integrate Telegram into ZAQ via the `jido_chat_telegram` fork so that the Telegram polling worker receives messages and routes them through the ZAQ agent pipeline, allowing the bot to reply to DMs.

---

## Context

- `jido_chat_telegram` fork lives at `../forks/jido_chat_telegram` (local path dep)
- ZAQ uses `jido_chat` as the chat abstraction layer
- ExGram 0.65 changed response format from plain maps to typed structs
- Req 0.5 requires options to be registered before use
- ZAQ agent pipeline (`Chat.process_message` → handler → LLM) runs synchronously inside the State GenServer

**Files reviewed:**
- `lib/zaq/channels/jido_chat_bridge.ex`
- `lib/zaq/channels/jido_chat_bridge/state.ex`
- `../forks/jido_chat_telegram/lib/jido/chat/telegram/adapter.ex`
- `../forks/jido_chat_telegram/lib/jido/chat/telegram/polling_worker.ex`
- `../forks/jido_chat_telegram/lib/jido/chat/telegram/transport/ex_gram_client.ex`
- `../forks/jido_chat_telegram/lib/jido/chat/telegram/ex_gram_adapter.ex`

---

## Problems Encountered and How They Were Solved

### 1. `Jido.Chat.FileUpload.__struct__/1 is undefined`

**Cause:** The `jido_chat` dependency was pinned to an old SHA that predated `Jido.Chat.FileUpload`.

**Fix:** `mix deps.update jido_chat` — updated SHA from `5b6bbe24` to `093f78db`.

---

### 2. `{:no_bridge, "telegram"}` at runtime

**Cause:** The `:channels` config map in `config/config.exs` had no `:telegram` entry.

**Fix:** Added the entry:

```elixir
telegram: %{
  bridge: Zaq.Channels.JidoChatBridge,
  adapter: Jido.Chat.Telegram.Adapter,
  ingress_mode: :polling,
  sink_mfa: {Zaq.Channels.JidoChatBridge, :from_listener, []}
}
```

---

### 3. `mix.exs` pointing to GitHub instead of local fork

**Cause:** `jido_chat_telegram` dep was referencing GitHub.

**Fix:** Changed to `path:` dep:

```elixir
{:jido_chat_telegram, path: "../forks/jido_chat_telegram", override: true}
```

---

### 4. `missing Telegram bot token for polling worker`

**Cause:** `polling_worker_opts/2` in the adapter only looked for the token in `ingress` and `credentials` keys, but ZAQ passes it via `opts[:token]`.

**Fix:** Added `opts[:token]` as a third fallback in `adapter.ex`:

```elixir
token:
  map_get(ingress, [:token, "token"]) || map_get(credentials, [:token, "token"]) ||
    opts[:token]
```

---

### 5. `{:unsupported_method, "getUpdates"}` — ExGram module not loaded

**Cause:** `ex_gram_client.ex` called `function_exported?(ExGram, :get_updates, 1)` before ExGram was loaded into the BEAM. `function_exported?` returns false for unloaded modules.

**Fix:** Added `Code.ensure_loaded?` before `function_exported?`, matching the pattern already used in `request_adapter/4` in the same file:

```elixir
cond do
  Code.ensure_loaded?(module) and function_exported?(module, :get_updates, 1) ->
    apply(module, :get_updates, [method_opts ++ ex_gram_runtime_opts(token, opts)])
  Code.ensure_loaded?(module) and function_exported?(module, :get_updates, 0) ->
    apply(module, :get_updates, [])
  true ->
    {:error, {:unsupported_method, "getUpdates"}}
end
```

**Rejected approach:** Calling `apply(ExGram, :get_updates, [...])` directly — this removed the API version flexibility that the `function_exported?` pattern provides.

---

### 6. `Req.TransportError{reason: :timeout}` on long-poll requests

**Cause:** `ExGramAdapter` was not setting `receive_timeout` on the Req request. Req 0.5 also requires options to be registered via `register_options/2` before they can be set with `put_new_option/3`.

**Fix:** Register the option first, then set it:

```elixir
|> Req.Request.register_options([:base_url, :json, :form_multipart, :receive_timeout])
|> Req.Request.put_new_option(:receive_timeout, receive_timeout)
```

Default timeout is 60 seconds (configurable via `:jido_chat_telegram, :receive_timeout_ms`).

---

### 7. `raw: invalid type: expected map` — ExGram struct rejected by `Zoi.map()`

**Cause:** ExGram 0.65 returns typed structs (e.g. `%ExGram.Model.Message{}`) instead of plain maps. `Jido.Chat.Incoming` validates `raw` with `Zoi.map()`, which rejects structs even though `is_map(struct)` is true.

**Fix:** Pass `raw: %{}` in `transform_message` (and the slash command path) since `raw` is an optional debug field:

```elixir
raw: %{}
```

**Rejected approach:** `Map.from_struct(message)` — this converted the struct but broke message receiving because nested structs were left unconverted, causing downstream pattern matches to fail.

---

### 8. `no function clause matching in Router.send_typing/2` with integer chat ID

**Cause:** Telegram chat IDs are integers. ZAQ's `Router` has guards requiring `is_binary(channel_id)`.

**Fix:** Stringify IDs in `JidoChatBridge.to_internal/2`:

```elixir
channel_id: incoming.external_room_id && to_string(incoming.external_room_id),
thread_id:  incoming.external_thread_id && to_string(incoming.external_thread_id),
message_id: incoming.external_message_id && to_string(incoming.external_message_id)
```

---

### 9. `GenServer.call` timeout on `refresh_config` — State blocked by LLM pipeline

**Cause:** `from_listener` called `refresh_config` as a synchronous `GenServer.call` (5 s default timeout) on every incoming message. The State GenServer processes the LLM pipeline synchronously inside `Chat.process_message`, which takes longer than 5 s. The next message's `from_listener` call would then time out waiting for State to become available.

**Fix:** Converted `refresh_config` to a `GenServer.cast` (fire-and-forget). Config refresh does not need to block the caller — it only updates handlers/adapters from the latest DB config, and the polling worker does not depend on the return value:

```elixir
def refresh_config(pid, config) do
  GenServer.cast(pid, {:refresh_config, config})
end
```

---

### 10. `author.is_me` nil crash in handler

**Cause:** The `on_new_message` handler in `JidoChatBridge.register_handlers` accessed `incoming.author.is_me` directly. For some Telegram messages (e.g. service messages), `author` can be nil.

**Fix:** Guard with nil-safe access:

```elixir
is_me = incoming.author && incoming.author.is_me
is_dm = incoming.channel_meta && incoming.channel_meta.is_dm
if is_dm and not is_me do
  handle_message_event(config, thread, incoming)
end
```

---

## Key Architecture Notes

- **State GenServer is the single owner of `%Jido.Chat{}`** — all incoming mutations are serialized through it. This is correct and intentional; no change needed.
- **LLM pipeline runs synchronously inside `handle_cast`** — this means the State GenServer is unavailable during LLM inference. All callers that don't need a return value (like `refresh_config`) must use `cast`. Callers that do need a reply (`send_reply`, `send_typing`) correctly use `call` with `:infinity` timeout.
- **ExGram 0.65 breaking change** — response bodies are now typed structs, not plain maps. Any code that passes ExGram responses directly to `Jido.Chat` types validated with `Zoi.map()` will fail. The fix is to use `raw: %{}` or explicitly convert only the fields needed.

---

## Definition of Done

- [x] Telegram polling worker starts and receives messages
- [x] Messages route through `JidoChatBridge` into the ZAQ agent pipeline
- [x] No GenServer crashes on normal message flow
- [x] `mix compile` passes with no warnings
- [ ] Tests written for adapter transform and bridge flow
- [ ] `mix precommit` passes
