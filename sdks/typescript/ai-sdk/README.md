# @zaq/ai-sdk

Vercel AI SDK adapter for ZAQ's AG-UI transport.

Turns a ZAQ `/ag-ui/runs` event stream into a `useChat`-compatible
`UIMessage` stream — the missing bridge between ZAQ's AG-UI backend and
the Vercel AI SDK's `useChat` hook.

## What it does

ZAQ exposes an AG-UI HTTP+SSE endpoint (`/ag-ui/runs`). The Vercel AI SDK's
`useChat` hook expects a stream of `UIMessageChunk` objects. This package
bridges the two:

```
useChat (browser)
  └─ POST /api/chat (your proxy route)
        └─ aguiHttpAgentEventStream → ZAQ /ag-ui/runs (SSE)
              └─ aguiToUIMessageStream → ReadableStream<UIMessageChunk>
                    └─ createUIMessageStreamResponse → Response
```

Key behaviours:

- **Token streaming** — ZAQ token-streams its answer; each
  `TEXT_MESSAGE_CONTENT` delta is forwarded 1:1 as a `text-delta`.
- **Provenance marker stripping** — ZAQ annotates answers with
  `[[source:…]]` / `[[memory:…]]` routing tags. These are stripped before the
  text reaches the UI, even when a marker is split across streamed deltas.
- **Citation → source-url** — `CUSTOM` events named `citation`, `source`,
  `cite`, or `reference` are mapped to AI SDK `source-url` parts so the UI
  can render footnotes.
- **HITL interrupts** — `RUN_FINISHED` with `outcome.type === "interrupt"`
  surfaces the pending interrupt descriptors as `data-zaqEvent` parts so your
  UI can render an approval prompt.
- **Tool call pass-through** — `TOOL_CALL_*` events are forwarded as AI SDK
  `tool-input-*` / `tool-output-available` parts (dynamic tool mode).

## Install

```bash
npm install @zaq/ai-sdk
# peer dependency — must be installed separately
npm install ai
```

## Usage

### 1. Proxy route (server-side)

Create a Next.js (or any Node) API route that holds the ZAQ bearer token
server-side and proxies the AG-UI event stream to the browser as an AI SDK
`UIMessageStream`.

```ts
// app/api/chat/route.ts  (Next.js App Router example)
import { createUIMessageStreamResponse } from "ai";
import {
  aguiHttpAgentEventStream,
  aguiToUIMessageStream,
  toAGUIMessages,
  type RunAgentInput,
} from "@zaq/ai-sdk";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const { messages, threadId, runId } = await request.json();

  const input: RunAgentInput = {
    threadId,
    runId,
    state: {},
    messages: toAGUIMessages(messages),
    tools: [],
    context: [],
    forwardedProps: {},
  };

  const events = aguiHttpAgentEventStream({
    url: process.env.ZAQ_AGUI_URL!,   // e.g. http://zaq-server/ag-ui/runs
    token: process.env.ZAQ_API_KEY!,  // bearer token — never sent to the browser
    input,
    signal: request.signal,
  });

  return createUIMessageStreamResponse({ stream: aguiToUIMessageStream(events) });
}
```

### 2. Client component

Wire `useChat` to the proxy route as usual — no ZAQ-specific changes needed
on the client.

```tsx
"use client";
import { useChat } from "ai/react";
import { useId } from "react";

export function Chat() {
  const threadId = useId();

  const { messages, input, handleInputChange, handleSubmit } = useChat({
    api: "/api/chat",
    body: { threadId },
    // Optional: generate a stable runId per submission
    generateId: () => crypto.randomUUID(),
  });

  return (
    <div>
      <ul>
        {messages.map((m) => (
          <li key={m.id}>
            <strong>{m.role}</strong>:{" "}
            {m.parts.map((p, i) =>
              p.type === "text" ? <span key={i}>{p.text}</span> : null,
            )}
          </li>
        ))}
      </ul>
      <form onSubmit={handleSubmit}>
        <input value={input} onChange={handleInputChange} />
        <button type="submit">Send</button>
      </form>
    </div>
  );
}
```

### 3. Handling ZAQ-specific data parts

ZAQ side-data (state snapshots, custom widget payloads) arrives as
`data-zaqEvent` parts on each `UIMessage`. Access them via the message parts:

```ts
for (const part of message.parts) {
  if (part.type === "data-zaqEvent") {
    const { kind, value } = part.data; // ZaqEventDataPart
    if (kind === "state-snapshot") {
      // value is the ZAQ workflow state at this point in the run
    }
  }
}
```

## API

### `aguiToUIMessageStream(events, options?)`

Core adapter. Converts `AsyncIterable<AGUIEvent>` → `ReadableStream<UIMessageChunk>`.

| Option | Type | Default | Description |
|---|---|---|---|
| `onUnknownEvent` | `(event) => void` | — | Called for unrecognised CUSTOM events |
| `generateId` | `() => string` | `zaq-N` counter | Override for deterministic IDs in tests |

### `aguiHttpAgentEventStream(options)`

Runs a ZAQ AG-UI agent via `@ag-ui/client`'s `HttpAgent` and yields the
decoded, validated `BaseEvent` stream as `AsyncIterable<BaseEvent>`.

| Option | Type | Required | Description |
|---|---|---|---|
| `url` | `string` | yes | Full AG-UI runs endpoint |
| `token` | `string` | yes | Bearer token (server-side only) |
| `input` | `RunAgentInput` | yes | AG-UI run input (built from `toAGUIMessages`) |
| `signal` | `AbortSignal` | no | Wired to `agent.abortRun()` on disconnect |

### `toAGUIMessages(uiMessages)`

Converts `UIMessage[]` (AI SDK conversation history) into `AGUIMessage[]`
for `RunAgentInput.messages`. Strips client-only parts (reasoning, data,
source, file) — only role and text content are forwarded.

## Development

```bash
bun install
bun run check-types   # TypeScript check
bun run test          # Vitest
bun run build         # tsc → dist/
```

## License

MIT
