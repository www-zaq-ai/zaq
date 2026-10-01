# OpenAI-compatible Chat Completions endpoint

`POST /v1/chat/completions` lets any OpenAI Chat Completions client (OpenAI
SDKs, Vercel AI SDK `@ai-sdk/openai-compatible`, LangChain, curl) chat with a
ZAQ knowledge base. It is the `chat` channel: requests go through the same
routing, Person resolution, permission-scoped retrieval, traces and
conversation storage as every other channel.

This document is the contract. Each rule has an identifier; the acceptance
tests in `test/zaq_web/controllers/chat_completions_controller_test.exs` and
`test/zaq_web/endpoint_chat_auth_test.exs` quote it in their names.

Implementation: `ZaqWeb.Plugs.ChatBearerAuth` (authentication),
`ZaqWeb.ChatCompletionsController` (wire contract), `Zaq.Channels.ChatBridge`
(channel bridge) and `Zaq.Agent.ClientToolRun` (runs with caller tools).

## Configuration

| Setting | Default | Meaning |
| --- | --- | --- |
| `ZAQ_CHAT_TOKEN` (environment) | unset | Shared bearer token of the calling backend. Unset or empty disables the endpoint (AUTH-3). |
| `config :zaq, :chat_keepalive_ms` | `10_000` | Interval of SSE keepalive comments while no content is produced (SSE-5). |
| `config :zaq, :chat_result_timeout_ms` | `120_000` | Idle timeout: longest wait for the next content or the result (ERR-2, ERR-3). |

## Trust model

The bearer token authenticates the calling **service** (a trusted backend),
never an end user. The backend authenticates its own users and passes their
stable id as `user`. Every identity field of the body is therefore an
unverified claim: it may key a Person owned by the `chat` channel, and nothing
else (ID-3).

## Authentication

- **AUTH-1** Every `/v1/*` request needs `Authorization: Bearer <ZAQ_CHAT_TOKEN>`.
  The token is compared in constant time.
- **AUTH-2** A missing header is `401 {"error":{"message":"missing bearer token"}}`;
  a wrong token is `401 {"error":{"message":"invalid bearer token"}}`.
- **AUTH-3** Fail closed: while `ZAQ_CHAT_TOKEN` is unset or empty, every request
  is `503` with a message containing `not configured`, whatever it carries.
- **AUTH-4** Authentication happens before the request body is read.

## Request

```json
{
  "model": "zaq-chat",
  "user": "end-user-42",
  "conversation_id": "4b0f3c1e-6f0a-4d8e-9a57-2a1d3f1c9b10",
  "stream": true,
  "stream_options": {"include_usage": true},
  "messages": [
    {"role": "system", "content": "Answer in two sentences."},
    {"role": "user", "content": "What was decided on 18 June?"}
  ],
  "source_filter": ["council/minutes"],
  "zaq_user": {"name": "Jeanne Martin"},
  "tools": [],
  "tool_choice": "auto"
}
```

- **REQ-1** `messages` must be an array (`400 messages must be an array`) of at
  most 200 entries (`413 too many messages (max 200)`). The question is the text
  of the **last** `user` message; it must be non-empty
  (`400 no user message provided`). A message `content` is a string or an array
  of parts whose `text` values are concatenated.
- **REQ-2** `user` is required, a non-empty string
  (`400 user (owner id) is required`).
- **REQ-3** `conversation_id` is required (`400 conversation_id is required`) and
  must be a UUID (`400 invalid conversation_id`).
- **REQ-4** The first `system` message frames this run only: the model receives
  it before the question. It is never stored.
- **REQ-5** `model` is echoed back (default `"zaq-chat"`). It never selects the
  LLM: the answering agent's configured model is used.

Every rejected request is answered before the model is called, with the body
`{"error": {"message": "..."}}`.

## Conversations

- **CONV-1** The first request with an unknown `conversation_id` opens a `chat`
  conversation owned by `user`. Concurrent first requests for the same id from
  different users cannot both own it: the loser gets CONV-2.
- **CONV-2** A conversation is used only when its owner is `user` **and** it is a
  `chat` conversation. Otherwise the answer is
  `403 conversation does not belong to user`, before the model is called and
  without touching the conversation. Conversations of other channels (Back
  Office, Slack, ...) are never reachable, even with a matching owner id.
- **CONV-3** History is server-side. The model receives the stored turns of the
  conversation; the caller sends only the new message. Earlier turns a client
  resends are ignored (the tool exchange of TOOL-7 excepted). Conversations do
  not share history, even for the same user.
- **CONV-4** A completed turn stores the question as the user asked it (without
  the REQ-4 framing) and the final answer.

## Identity and retrieval scope

- **ID-1** The caller's `user` keys one Person on the `chat` channel, reused by
  every request carrying that id.
- **ID-2** `zaq_user.name`, when given, names that Person. A Person first seen
  without a name is renamed when a name arrives.
- **ID-3** No other identity claim is honoured. In particular an email in the
  request (for example `zaq_user.email`) is ignored: it can never select an
  existing Person nor change one.
- **ID-4** Knowledge-base retrieval runs with that Person's permissions; document
  permissions are never bypassed. A new chat Person belongs to no team, so it
  reads public documents only, unless an administrator grants more.
- **ID-5** `source_filter` (a string or an array of strings) narrows retrieval to
  the given folders (all documents under `<folder>/`) or exact document sources.
  It never widens what ID-4 allows. Absent or empty means unrestricted.

## Non-streaming response

```json
{
  "id": "chatcmpl-1234",
  "object": "chat.completion",
  "created": 1790000000,
  "model": "zaq-chat",
  "choices": [
    {
      "index": 0,
      "message": {"role": "assistant", "content": "The budget was adopted."},
      "finish_reason": "stop"
    }
  ],
  "zaq_sources": [{"sourceId": 12, "title": "council/minutes/2025-06-18.md", "page": 3}],
  "usage": {"prompt_tokens": 300, "completion_tokens": 30, "total_tokens": 330}
}
```

- **RESP-1** A `chat.completion` object: `id` (`chatcmpl-...`), `object`,
  `created` (Unix seconds), `model` (REQ-5), one choice with index `0`, the
  assistant message and `finish_reason` `"stop"` (or `"tool_calls"`, TOOL-4),
  and `zaq_sources` (CITE-1).
- **RESP-2** Inline citation markers the model writes (`[[source:...]]`,
  `[[.source:...]]`) are removed from the text, with the whitespace before
  them; citations travel in `zaq_sources`.

## Streaming response

With `"stream": true` the response is `text/event-stream`:

```text
data: {"id":"chatcmpl-1234","object":"chat.completion.chunk","created":1790000000,"model":"zaq-chat","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

: keepalive

data: {...,"choices":[{"index":0,"delta":{"content":"The budget "},"finish_reason":null}]}

data: {...,"choices":[{"index":0,"delta":{"content":"was adopted."},"finish_reason":null}]}

data: {...,"choices":[{"index":0,"delta":{},"finish_reason":null}],"zaq_sources":[...]}

data: {...,"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: {...,"choices":[],"usage":{"prompt_tokens":300,"completion_tokens":30,"total_tokens":330}}

data: [DONE]
```

- **SSE-1** The headers and a first chunk with `delta: {"role": "assistant"}` are
  sent as soon as the request is accepted, before the model answers.
- **SSE-2** Every `data:` frame but `[DONE]` is a complete
  `chat.completion.chunk`: the same `id`, `object`, `created` and `model` on
  every frame, and `choices` holding at most one choice with index `0` and a
  `delta` object (`choices` is empty only in the USAGE-2 chunk).
- **SSE-3** Content is streamed while the model generates. The concatenated
  `delta.content` values are the final answer, cleaned as in RESP-2, exactly
  once: a citation marker never reaches the wire, even when the model's output
  splits it. Text the model streams before calling one of ZAQ's own tools stays
  on the wire; the final answer then follows, after a paragraph break.
- **SSE-4** A terminal chunk with an empty `delta` and `finish_reason` `"stop"`
  (or `"tool_calls"`, TOOL-4) ends the choice; `data: [DONE]` ends the stream.
- **SSE-5** While no content is produced, an SSE comment `: keepalive` is sent
  every `chat_keepalive_ms`. Non-streaming responses never carry keepalive
  bytes.

## Token usage

- **USAGE-1** `usage` (`prompt_tokens`, `completion_tokens`, `total_tokens`) is
  the token usage the LLM provider reported for the model calls of this
  request, summed over all of them (including the calls of ZAQ's internal tool
  loop). It is part of every successful non-streaming response, tool calls
  included.
- **USAGE-2** When streaming with `"stream_options": {"include_usage": true}`,
  one last chunk with `"choices": []` and `usage` follows the terminal chunk,
  before `[DONE]`. Without that option no usage is streamed.
- **USAGE-3** The numbers are never estimated: when the provider reports no
  usage, `usage` is absent and no usage chunk is sent.
- **USAGE-4** A failed run (ERR-1, TOOL-10, TOOL-12) still reports the usage
  of the model calls it made, under USAGE-1..3. Not streaming, the `502` body
  carries `usage` beside `error` (`{"error": {...}, "usage": {...}}`; clients
  that only read `error` ignore it). Streaming with `include_usage`, the usage
  chunk follows the in-band error chunk, before `[DONE]`. A request that ends
  before its run reports (ERR-2) carries no usage.

## Citations

- **CITE-1** `zaq_sources` lists the documents retrieved to answer, one entry per
  document and page, at most 8, in retrieval order: `sourceId` (document id),
  `title` (document source path) and `page` (first page of the cited passage;
  `null` for documents without pages). Only documents the caller may read are
  cited (ID-4). The non-streaming response always carries the array, possibly
  empty.
- **CITE-2** When streaming, citations ride one chunk with an empty `delta`,
  `finish_reason: null` and `zaq_sources`, sent before the terminal chunk (a
  client stops reading at `finish_reason`). No such chunk is sent when nothing
  was retrieved.

Clients unaware of `zaq_sources` ignore it.

## Errors and timeouts

- **ERR-1** A failed run (the LLM provider fails, the run errors or produces no
  answer) is `502 {"error":{"message":...}}` when not streaming. When
  streaming, the status is already `200`, so the error travels in-band: a last
  chunk whose `delta.content` is the error message, `finish_reason: "stop"`
  and an extra `error: {"message": ..., "type": "server_error"}`, then
  `[DONE]`. Clients that only read `choices` still show the message.
- **ERR-2** When no content and no result arrives within `chat_result_timeout_ms`,
  the request ends with ERR-1 and the message
  `The answer took too long. Please try again.`
- **ERR-3** The timeout is an idle timeout: each streamed content delta restarts
  it, so a long answer that keeps flowing is never cut. Keepalives do not
  restart it.

## Cancellation

- **CANCEL-1** When streaming, a request whose client has gone stops at the
  first write that fails (a content delta or a keepalive, so within
  `chat_keepalive_ms` while the model is silent): nothing more is written. A
  non-streaming request cannot notice a disconnect before it answers.
- **CANCEL-2** A request that ends before its run's result (CANCEL-1, or the
  ERR-2 timeout) cancels the run, with or without caller tools: no further
  model call starts, and the model call in progress is abandoned at its next
  streamed chunk, closing the provider connection.
- **CANCEL-3** A cancelled turn is not stored: neither the question nor any
  partial answer joins the conversation (CONV-4), so the caller can ask again.
  A run that finished before the disconnect was noticed has already stored its
  turn.

Limitation, runs without caller tools: they run on the agent server, which
`Jido.AI.Agent.cancel/2` cancels. The request ends at once and nothing is
stored, but a cancel that reaches the agent server before its worker's model
call is under way is not seen by the worker, which then completes the turn in
the background; and the abandoned question stays in the working memory of the
conversation's agent server until that server restarts. Runs with caller tools
have neither limitation.

## Caller-executed tools

Tools the **caller** executes follow OpenAI's protocol. ZAQ's own tools
(knowledge-base search and overview) keep running inside ZAQ.

- **TOOL-1** `tools` must be an array (`400 tools must be an array`) of at most
  128 (`400 too many tools (max 128)`) function tools
  `{"type": "function", "function": {"name": ..., "description"?, "parameters"?}}`
  with non-empty, unique names (`400 each tool must be {"type": "function", ...}`,
  `400 tool names must be unique`).
- **TOOL-2** `tool_choice` is `"auto"`, `"none"`, `"required"` or
  `{"type": "function", "function": {"name": N}}` with `N` in `tools`
  (`400 invalid tool_choice`,
  `400 tool_choice names a function that is not in tools`).
- **TOOL-3** The model is offered the caller's tools (name, description,
  parameters) beside ZAQ's own. `tool_choice` constrains the model's first call
  of the request only; once one of ZAQ's tools has answered, the model chooses
  freely. With `"tool_choice": "none"` the caller's tools are not offered.
- **TOOL-4** When the model calls caller tools, the turn ends.
  Non-streaming: `message.tool_calls` lists them
  (`{"id", "type": "function", "function": {"name", "arguments"}}`,
  `arguments` a JSON string), `message.content` is `null` unless the model also
  wrote text, and `finish_reason` is `"tool_calls"`. Streaming: one chunk whose
  `delta.tool_calls` lists them, each with its `index`, then the terminal chunk
  with `finish_reason: "tool_calls"`.
- **TOOL-5** Calls to ZAQ's own tools run server-side with the caller's
  permissions (ID-4, ID-5) and never appear in `tool_calls`; what they retrieve
  is still cited (CITE-1).
- **TOOL-6** A tool exchange is the run of `assistant` (with `tool_calls`) and
  `tool` messages after the last `user` message. It is rejected with `400` when
  a `tool` message answers an unknown `tool_call_id`
  (`tool message references an unknown tool_call_id`), when a call has no
  answering `tool` message (`every tool_call needs a tool message answering it`),
  when `arguments` is not a JSON object string
  (`tool_calls arguments must be a JSON object string`), or when a call lacks
  `id` or `function.name` (`each tool_call needs an id and function.name`).
- **TOOL-7** To continue, the caller resends the same last `user` message
  followed by the assistant `tool_calls` message and one `tool` message per
  call. The model receives that exchange as native assistant tool calls and
  tool results after the question, with the stored history before it (CONV-3),
  and the turn continues.
- **TOOL-8** A turn paused on caller tool calls is not stored. When it
  completes, the question and the final answer are stored once (CONV-4).
- **TOOL-9** A caller tool cannot take the name of one of ZAQ's tools: the
  request fails as in ERR-1 without calling the model.
- **TOOL-10** ZAQ's internal tool loop is bounded by the answering agent's
  maximum iterations (10 by default); reaching it fails as in ERR-1.
- **TOOL-11** A model call to a tool that is neither one of ZAQ's tools nor one
  of the caller's is not executed: the model receives a tool result whose error
  names the unknown tool, and the turn continues (TOOL-10 bounds it).
- **TOOL-12** Runs with caller tools apply the answering agent's context window
  like every run: before each model call, stored history is dropped oldest
  turn first until the request fits the model's window (`max_context_window`
  less the reserved output). When the question, the tool exchange and the
  tools alone do not fit, the request fails as in ERR-1 without calling the
  model.
- **TOOL-13** Runs with caller tools record the same telemetry as runs without
  them: message, execution, answer, token and per-model-call metrics, with the
  same dimensions.

## Related

- [Channels](channels.md): bridges, `Incoming`/`Outgoing` and routing.
- [Agent](agent.md): answering agent, retrieval tools and permissions.
- [Engine](engine.md): conversation storage.
