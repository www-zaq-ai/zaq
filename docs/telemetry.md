# Telemetry Runtime Notes

## Buffer flush behavior

`Zaq.Engine.Telemetry.Buffer` stores telemetry points in memory and flushes them
to `telemetry_points` using batched `Repo.insert_all/3` writes.

Flush triggers:

- periodic timer (`flush_interval_ms`)
- batch size threshold (`max_batch_size`)
- explicit `Zaq.Engine.Telemetry.Buffer.flush/2`

Graceful shutdown behavior:

- `Zaq.Application.prep_stop/1` performs a best-effort explicit buffer flush
- `Zaq.Engine.Telemetry.Buffer.terminate/2` performs a best-effort final flush

This improves persistence of in-flight telemetry points during graceful stop.

## Limitations

This is still an in-memory buffer. In cases like VM crash, OS kill (`SIGKILL`),
or power loss, points that have not been flushed yet can still be lost.
