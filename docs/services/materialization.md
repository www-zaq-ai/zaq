# Materialization Service

## Overview

`Zaq.Materialization` redeems signed, JSON-safe handles for records whose content is
available from another service role.

Records carry metadata plus optional `materialization_handle`. The handle is a signed
bearer locator: possession is enough to redeem content because handles are only disclosed
on Records after the data-source boundary authorizes `read` access. It contains only:

- `v` — handle version
- `type` — allowlisted materializer key
- `locator` — materializer-specific primitive fields

Handles intentionally do not contain destination roles, actions, modules, credentials,
actors, or permission decisions. Do not mint or expose a materialization handle for a
Record until its caller is authorized to read that Record; redemption does not re-check
provider ACLs.

`Zaq.Events.TrustedContext` is the only reusable projection of that runtime context across
role and bridge boundaries. It retains the canonical actor and literal
`skip_permissions: true`; credentials, arbitrary event options, request parameters, and
runtime module overrides are not transported. Event builders may consume local router and
config dependencies without storing them in the transported context.

## Flow

1. A source adapter returns an unmaterialized `%Zaq.Contracts.Record{}` with
   `content: nil` and `materialization_handle`.
2. JSON/tool serialization preserves the signed handle.
3. `Zaq.Materialization` verifies the handle and looks up the materializer type in
   `Zaq.Materialization.Registry`.
4. `Zaq.Materialization` validates per-redemption options against the handler's
   declared option list. Options must have string keys; atom keys and undeclared keys
   are rejected as `:invalid_materialization_options`, not normalized.
5. The trusted handler validates the locator and builds a fixed `%Zaq.Event{}` through
   role event helpers.
6. `NodeRouter` routes by role to any node running that service.
7. Returned content is normalized into `%{record: %Zaq.Contracts.Record{}}`.

## Data Source Documents

`data_source_document` is implemented by
`Zaq.Channels.Materializers.DataSourceDocument`.

Locator fields:

- `provider` — provider key, validated again by Channels when `config_id` is present
- `file_id` — provider document identifier
- `config_id` — optional explicit data-source configuration
- `document_mime_type` — optional source MIME type for export decisions

Per-redemption options:

- `document_mime_type` — optional source MIME type when the caller needs to override or
  supply representation metadata outside the signed locator.
- `export_mime_type` — optional requested export MIME type. This is request-time
  representation state, not document identity, so it is passed separately from the
  signed locator. When present it overrides any configured default for the source
  MIME type.

`data_source_document` declares `document_mime_type` and `export_mime_type` in
`materialization_options/0`; validation is centralized in `Zaq.Materialization`.

The handler always dispatches `:data_source_download_document` to the Channels role via
`Zaq.Channels.Events`; callers cannot select another action. Channels passes the normalized
trusted context to data-source file callbacks as a separate argument rather than embedding
identity or permission flags in provider parameters.

## Communication Media

`communication_media` is implemented by
`Zaq.Channels.Materializers.CommunicationMedia`.

Communication history stores durable source metadata, not handles. Channels
builders use `source_metadata/3` and `issue/4` with the same normalized locator.
Confidential history hydration reconstructs a lazy Record and newly issues its
handle without downloading bytes. Handles are deterministic signed locators, not
node-local references or expiring tokens: reissuance need not change their bytes.
Runtime aliases are separate and scoped to the logical agent server. Redemption
still validates the actor and current connector, and IMAP still checks UIDVALIDITY.

Locator fields include `provider`, `reference`, optional display metadata
(`name`, `mime_type`, `media_kind`, `size`), optional config provenance
(`channel_config_id`), and source provenance (`source_author_id`,
`source_channel_id`, `source_message_id`). Canonical history hydration adds a
version-1 `canonical_attachment` claim binding the canonical `transcript_id` and
`message_id`. This runtime claim is signed but never persisted into source metadata.
Each redemption reads that exact message through Engine's existing `:conversation`
event with `action: :canonical_message`, using the trusted event actor. Engine
reuses the transcript-read policy and returns its sanitized message projection.
Channels then checks the returned placement and matches the stored attachment's
identity and complete normalized durable source against the signed locator before
dispatching `:materialize_record`. Read failures, missing/ambiguous attachments and
source mismatches fail before provider I/O. The original author remains provenance,
not the permission decision: any current authorized transcript reader can download.
Revoking all effective read grants invalidates future canonical downloads, including
the uploader's, while a surviving manual grant remains effective.

Unscoped handles retain the author-ID check and explicit trusted-internal
`skip_permissions: true` compatibility. A present invalid/unknown canonical claim
never falls back to that legacy policy, even with permission bypass. Existing rich
stored descriptors gain scoped handles through fresh authorized hydration; legacy
display-only descriptors remain unavailable. Deploy the updated materializer on all
executing roles before issuing scoped handles; old unscoped handles retain their old
restrictions until rehydrated. Signed provider provenance still routes the existing
fetch, and model arguments cannot override it. Authorization cannot retract bytes
already delivered.

IMAP email attachments use the same `communication_media` materializer. Their
locator additionally binds `mailbox`, `uid_validity`, `uid`, MIME `section`, and
transfer `encoding`. Email redemption routes to the exact enabled
`channel_config_id`, verifies it is an `email:imap` config, rechecks current
`UIDVALIDITY`, fetches one `BODY.PEEK[section]`, decodes supported transfer
encodings, and returns a materialized file `Record`.

## Disk Documents

`disk_document` is implemented by `Zaq.Storage.Materializers.DiskDocument`.

Locator fields:

- `file_id` — the stable Storage entry id, the same id `Zaq.Channels.DiskBridge`
  puts on every disk record it returns
- `config_id` — optional Disk data-source `ChannelConfig` id. Storage reads the
  current persisted config at redemption time and fails closed if the config is
  disabled, missing, or ambiguous.

Per-redemption options:

- `document_mime_type` — accepted for cross-source compatibility with data-source
  document redemption. Storage currently ignores it and returns the raw disk bytes.
- `export_mime_type` — accepted for cross-source compatibility with data-source
  document redemption. Storage currently ignores it until export conversion is implemented.

The handler always dispatches `:materialize_document` directly to the Storage role via
`Zaq.Storage.Events`. A consumer that already has a Disk record redeems this handle without
going back through Channels. Provider-plus-id consumers still use the generic
`data_source_document` path first; for Disk, that Channels hop returns an unmaterialized
record carrying the `disk_document` handle, and `Zaq.Materialization` redeems that second
handle against Storage.

## Acquisition: streaming, sinks and quotas

Redeeming a handle never needs to hold a whole source in memory. Consumers pick one of two
entry points:

- `Zaq.Materialization.materialize_file/5` — for consumers that need a **file** (ingestion).
  Returns the record without content plus `file: %{path, size, binary?, sink}`. The sink keeps
  owning the finished file until the caller adopts it and calls `complete_file/1` (or gives it
  up with `discard_file/1`); only then does the caller own the file and its directory. `file`
  is `nil` when the producer cannot stream and returned
  `content` inline (rows, small provider attachments); that content stays in
  `record.content` after a post-hoc size check.
- `Zaq.Materialization.materialize/4` — the **bounded bytes** API for consumers that need the
  bytes themselves (model tool results, previews). Unchanged result shape. Acquisition
  stops at `config :zaq, :materialization_max_bytes` (default 50 MiB) instead of buffering
  an unbounded body.

Both open a consumer-owned `Zaq.Materialization.Sink` and pass its pid to producers as a
trusted event option (`materialization_sink`, in the handler context under the same key). The
sink is a write capability for one consumer-owned file (or memory buffer) with a hard byte
quota:

- Chunks are written with synchronous calls, so a producer cannot outrun the consumer (one
  chunk in flight). The same sink flows through nested handles, so nested materialization
  shares one quota and cannot reset it.
- Exactly `max_bytes` is accepted, one more is rejected without storing the chunk. A known
  source size (stat, `content-length`) rejects early; the running count is what is enforced,
  so missing or stale length metadata is covered.
- The consumer's node is the only place a path exists. A producer on another node only sends
  chunks to the sink pid over the normal distribution link; paths, `File.Stream`s and open
  devices are never serialized and the sink is never read from handles, tool options or
  request params (`Channels.Api` drops a request-supplied value).
- Overflow, source errors, failed writes, `discard/1` and **consumer exit** (the sink monitors
  its owner) close the device and delete the partial `.part` file. A *finished* file is not
  unowned either: `finish/1` keeps the sink alive and monitoring until the caller confirms
  the hand-over with `release/1` (`Materialization.complete_file/1`), so a consumer dying
  between completion and adoption leaves nothing behind. With `own_dir: true` (a directory made
  for this acquisition alone, as ingestion does) cleanup removes the whole directory, which
  covers a file already renamed inside it. Source files are never touched. Errors report only `materialization size limit exceeded (N bytes)` — no handle,
  credential or path.

Producers: Storage (`:materialize_document`) streams the volume file in 256 KiB reads;
`Zaq.Channels.JidoConnectBridge` hands Google Drive downloads/exports to
`StreamingDriveClient` through the dependency's `google_drive_client` credential seam, which
writes each chunk of a 2xx body to the sink. Transient GET retries stay on, except after body
bytes reached the sink. Provider error bodies keep their shape (capped at 64 KiB); non-identity
`content-encoding` is rejected.

JSON that `Req` would decode keeps its decoded meaning in both modes. The bytes API buffers it
up to *that call's* quota and the dependency normalizes it as before. A file sink receives a
top-level JSON array as the Markdown table ingestion builds from decoded rows
(`Zaq.Materialization.RowsMarkdown`, the single implementation of that conversion), rendered
row by row with the standard library's resumable decoder (`Zaq.Materialization.JsonArrayRows`),
so the array is never held: memory is one row, and the body and the rendered file are both held
to the quota. Any other JSON value (an object, which the dependency rejects, or a scalar) is
buffered up to the in-memory cap and handled by the dependency exactly as before. Producers that ignore the sink (other
bridges, Slack/Telegram/IMAP attachments) keep returning inline content. Inline content is
checked by byte length after it has already been acquired; Base64 is counted as decoded bytes,
including the effect of padding, without decoding another copy. This post-hoc check cannot bound
the producer's initial allocation.

The quota is a resource guard, not a substitute for streaming: file mode memory is one chunk
per acquisition, but disk use is up to `config :zaq, :materialization_max_file_bytes`
(default 2 GiB) per concurrent acquisition, and the in-memory API can hold up to
`:materialization_max_bytes` per concurrent call. A per-file budget alone is not a global
bound; size worker concurrency accordingly.

## Extension Rules

To add a new materializable source:

1. Add a handler implementing `Zaq.Materialization.Handler` in the owning service context.
2. Register a stable string key in `Zaq.Materialization.Registry`.
3. Declare supported per-redemption options through `materialization_options/0`.
4. Validate all locator fields strictly in the handler.
5. Build fixed role events through the owning role's event helper.
6. Add tampering, malformed input, registry, option validation, and role-routing tests.

Do not expose bridge modules, destination roles, action names, file paths, credentials, or
permission claims in handles.
