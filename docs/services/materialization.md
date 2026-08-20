# Materialization Service

## Overview

`Zaq.Materialization` redeems signed, JSON-safe handles for records whose content is
available from another service role.

Records carry metadata plus optional `materialization_handle`. The handle is a signed
locator, not an authorization grant. It contains only:

- `v` — handle version
- `type` — allowlisted materializer key
- `locator` — materializer-specific primitive fields

Handles intentionally do not contain destination roles, actions, modules, credentials,
actors, or permission decisions. Current authorization must come from the trusted runtime
context that redeems the handle.

## Flow

1. A source adapter returns an unmaterialized `%Zaq.Contracts.Record{}` with
   `content: nil` and `materialization_handle`.
2. JSON/tool serialization preserves the signed handle.
3. `Zaq.Materialization` verifies the handle and looks up the materializer type in
   `Zaq.Materialization.Registry`.
4. The trusted handler validates the locator and builds a fixed `%Zaq.Event{}` through
   role event helpers.
5. `NodeRouter` routes by role to any node running that service.
6. Returned content is normalized into `%{record: %Zaq.Contracts.Record{}}`.

## Data Source Documents

`data_source_document` is implemented by
`Zaq.Channels.Materializers.DataSourceDocument`.

Locator fields:

- `provider` — provider key, validated again by Channels when `config_id` is present
- `file_id` — provider document identifier
- `config_id` — optional explicit data-source configuration
- `document_mime_type` — optional source MIME type for export decisions

Per-redemption options:

- `export_mime_type` — optional requested export MIME type. This is request-time
  representation state, not document identity, so it is passed separately from the
  signed locator. When present it overrides any configured default for the source
  MIME type.

The handler always dispatches `:data_source_download_document` to the Channels role via
`Zaq.Channels.Events`; callers cannot select another action.

## Extension Rules

To add a new materializable source:

1. Add a handler implementing `Zaq.Materialization.Handler` in the owning service context.
2. Register a stable string key in `Zaq.Materialization.Registry`.
3. Validate all locator fields strictly in the handler.
4. Build fixed role events through the owning role's event helper.
5. Add tampering, malformed input, registry, and role-routing tests.

Do not expose bridge modules, destination roles, action names, file paths, credentials, or
permission claims in handles.
