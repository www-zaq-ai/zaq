# Extension Action exchange

The shared wire definition is [`priv/proto/gateway.proto`](../../priv/proto/gateway.proto).
This document defines the optional `actions.v1` capability. The Engine's
Extension runtime implements its admission, execution and receipt ledger;
a health-only streaming peer remains supported without Action access.

## Discovery and execution

`ListActions` returns only Registry metadata: stable `key`, human-readable `name`,
description and optional Action version. Entries are sorted by key. `page_size`
zero selects 50; 1–100 is accepted. `page_token` is the previous page's final
key, used as an exclusive cursor, with a maximum of 256 UTF-8 bytes. An empty
`next_page_token` ends enumeration. The catalog is not a durable snapshot.

`DescribeAction` returns that metadata plus an input JSON Schema and an optional
output JSON Schema, exported from the Action's declarations through
`Jido.Action.Schema`. An undeclared output schema is absent, not `{}`.
Registry membership is the discovery boundary; not every Action in the codebase
is exposed. Neither operation accepts an Elixir module name.

`ExecuteAction` takes a Registry key, a strict UTF-8 JSON object in
`arguments_json`, and an explicit `SYNC` or `ASYNC` mode. Unspecified and unknown
modes fail. `timeout_ms` is required for all three operations and must be between
1 and the negotiated maximum. It starts when ZAQ receives the request, includes
dispatch and serialization, and is not renewed by RELAYED.

ZAQ uses confidential Engine Events, preserves the invocation ID as `trace_id`,
and resolves the key through Registry. `ActionContract.execute/4` normalizes
arguments and invokes Jido with retries disabled. ZAQ creates trusted service
context with explicit permission opt-ins; no actor, permission flags, module,
callback, destination node or execution options are accepted from wire context.
Domain policies and credential resolution still apply. Existing Actions retain
their owning service calls; HTTP executes on Channels. Gateway owns commercial
authorization, signatures, result interpretation and business retries.

Results are strict JSON values encoded in `result_json`. Duplicate object keys
and malformed UTF-8 are rejected, including colliding atom/string result keys.
Existing atom-valued Action enums encode as JSON strings through Jason; no
untrusted strings are interned as atoms beyond the Action's declared schema.
Arbitrary Erlang terms
must not be stringified, atomized from input, or truncated into successful results.
Binary bodies require an Action-defined Base64 representation. HTTP statuses,
including non-2xx, belong to the HTTP Action result, not the transport error code.
Schema export is descriptive; it does not promise semantic version compatibility.

## Negotiation

Both peers must select `actions.v1` during the existing Hello exchange. ZAQ offers
the limits below; Gateway selects a value no larger than each offered value and
the selected envelope ceiling. Every field is required and nonzero. ZAQ rejects
inconsistent limits before executing any Action. Unknown optional capabilities
are not selected. A peer selecting only `health.v1` remains supported and must
not send Action requests or receipts.

| Limit | ZAQ offer | Valid selected minimum |
| --- | --- | --- |
| `max_concurrent` | 8 | 1 |
| `max_unreceipted_replies` | 32 | 2 |
| `max_unreceipted_bytes` | 67,108,864 | `max_reply_envelope_bytes + 512` |
| `max_timeout_ms` | 60,000 | 1 |
| `max_json_depth` | 32 | 1; never above 64 |
| `max_reply_envelope_bytes` | min(8,388,608, envelope ceiling) | 512 |
| `receipt_timeout_ms` | 60,000 | 1,000 |

The existing Global gRPC setting defaults to 64 MiB. Its negotiated envelope
ceiling bounds all complete encoded protobuf envelopes. Reply limits count the
entire encoded `ZaqEnvelope`, excluding the five-byte gRPC prefix, HTTP/2 headers
and TLS overhead. JSON depth counts an outer object/array as one; scalars add no
depth. No gRPC compression is negotiated by this capability.

## Correlation and outcomes

Action request IDs are canonical lowercase hyphenated UUIDv4 strings, globally
fresh across stream generations. The same envelope ID appears on RELAYED,
terminal reply and receipts. Replies can complete out of order across IDs.

SYNC sends one terminal reply. ASYNC is valid only for execute and sends RELAYED
after successful dispatch, before its terminal reply. RELAYED means neither
successful validation nor completed side effects. List and describe always send
one terminal reply. Failures before successful dispatch send only a failure.

A duplicate ID that is still executing, awaiting completion or awaiting any
receipt causes `ProtocolError.INVALID_ENVELOPE` and closes the stream. It never
produces a second ActionReply that could settle the original invocation. Invalid
UUIDs, absent/unknown operations and Action messages without negotiated capability
likewise cause an explicit protocol error and closure. Valid requests with invalid
arguments or unknown keys receive an ActionFailure when reply capacity is available.
Fresh IDs are mandatory even after receipt; bounded memory is not durable deduplication.

`effects_may_have_occurred` is conservative: false only when execution has not
started. An Action error, serialization failure, oversized result or deadline
after dispatch must not be interpreted as proof that no side effects occurred.
No failure code grants permission to retry automatically. Safe messages exclude
arguments, credentials, raw Action errors, stack traces and transport internals.

## Credits and receipts

Every ActionReply has a stream-wide sequence starting at one and increasing by
one in send order. Sequences do not restart per invocation. Gateway must promptly
receipt every reply, including RELAYED, with the same ID and sequence. A receipt
confirms transport consumption, not business acceptance, signature verification
or durable storage. Health, Hello, receipts and protocol errors do not consume
Action reply credits and are serviced independently of Action work.

Before admission, ZAQ reserves one reply slot and `max_reply_envelope_bytes` for
the terminal reply. ASYNC additionally reserves one slot and 512 bytes for RELAYED.
The actual encoded reply replaces its reservation on emission; surplus bytes are
released then. Only its exact receipt releases the remaining bytes and slot.
Reservations plus sent-but-unreceipted replies must stay within both selected
budgets. Running worker count must stay within `max_concurrent`.

A full worker pool can return RESOURCE_EXHAUSTED if a terminal reservation fits.
If even a bounded failure cannot be reserved, ZAQ sends the credit-independent
`ProtocolError.RESOURCE_EXHAUSTED` and closes the stream; it does not buffer
unbounded rejection replies. A result larger than the reserved reply ceiling is
replaced with RESULT_TOO_LARGE within the same terminal reservation. Failure
envelopes must fit 512 bytes. No partial result or application fragmentation exists.

The receipt deadline starts when the runtime hands the reply to its single
writer. This also bounds a blocked send; Gun's send acknowledgment proves queueing,
not peer receipt. Only one reply at a time is handed to that writer.

Receipts for zero, unknown, already receipted or mismatched sequences/IDs are
protocol violations and close the stream without releasing unrelated credits.
Gateway likewise rejects missing, repeated, skipped or non-increasing reply
sequences and impossible outcome transitions. Reliable ordered gRPC needs no
duplicate-receipt recovery. A sent reply not receipted within `receipt_timeout_ms`
closes the stream. Generation teardown releases transport reservations, not
execution capacity for workers that are still running.

## Deadlines and disconnection

ZAQ emits one DEADLINE_EXCEEDED terminal reply when its waiting deadline expires;
it does not cancel the Action. Execution capacity stays occupied until the actual
worker exits. A late completion is discarded, never emitted as a second terminal.

Gateway local timeout may occur first. It stops delivering outcomes to the caller
but retains bounded, generation-fenced bookkeeping for the ID until terminal reply
or disconnect. It continues consuming and receipting valid RELAYED/terminal replies.
Timed-out records still count against its pending admission budget, so repeatedly
timing out cannot accumulate unlimited tombstones. After a terminal reply, no
tombstone is needed because no second terminal is permitted. Unknown replies or
outcomes from an old generation cannot resolve a new invocation.

Disconnect makes unresolved outcomes unknown. Reconnection starts a fresh Hello,
sequence and credit ledger. No automatic invocation replay, durable execution,
cancellation or exactly-once execution is provided.

## Verification and HTTP scope

`test/zaq/engine/extension/action_stream_test.exs` exercises the encrypted stream's
discovery, execution, credits and rejection behavior. `action_http_test.exs` uses
the real HTTP Action, NodeRouter and Channels with a controlled external server
to verify concurrent completion, deadline accounting, confidentiality and old-stream
fencing. Confidential HTTP context propagates through both Channels and Engine
preparation events. Other Actions retain their own existing context contracts.

`action_wire_test.exs` checks ten independent golden envelopes shared with the
Rust gateway, including byte-preserved JSON numbers above 2^53. The opt-in
`rust_interoperability_test.exs` runs a real gateway Action probe: set
`GATEWAY_BINARY` and `GATEWAY_ACTION_PROBE_BINARY` to built binaries and run with
`--include commercial_gateway`. The probe deliberately executes benign
`arithmetic.add` twice, once in each mode.

Action exchange does not change the HTTP Action's decoded/truncated response
defaults or merge the separate raw-response work. Signed portal byte fidelity,
raw Base64 HTTP responses and distributed channel-only transport proof remain
separate integration requirements. No commercial policy executes in ZAQ's relay.
