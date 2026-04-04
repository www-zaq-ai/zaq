# Telemetry Runtime Notes

## Buffer flush behavior

`Zaq.Engine.Telemetry.Buffer` stores telemetry points in memory and flushes them
to `telemetry_points` using batched `Repo.insert_all/3` writes.

Flush triggers:

- periodic timer (`flush_interval_ms`)
- batch size threshold (`max_batch_size`)
- explicit `Zaq.Engine.Telemetry.Buffer.flush/2`

Graceful shutdown behavior:

- the telemetry buffer process `terminate/2` callback performs a best-effort final flush

This improves persistence of in-flight telemetry points during graceful stop.

## Metric naming conventions

`Zaq.Engine.Telemetry.record/4` persists metrics by prefix allowlist:

- business metrics (always allowed): `qa.*`, `feedback.*`, `ingestion.*`
- infrastructure metrics (opt-in only): `repo.*`, `oban.*`, `phoenix.*`

Notes:

- infra metrics are persisted only when callers pass `allow_infra: true`
- unknown prefixes are intentionally ignored
- keep metric keys lowercase, dot-separated, and domain-first (for example: `qa.answer.confidence`, `ingestion.documents.count`)

## Limitations

This is still an in-memory buffer. In cases like VM crash, OS kill (`SIGKILL`),
or power loss, points that have not been flushed yet can still be lost.
