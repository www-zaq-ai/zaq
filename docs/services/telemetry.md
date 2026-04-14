# Telemetry Service

## Overview

The Telemetry subsystem lives under `Zaq.Engine.Telemetry` and is supervised by
`Zaq.Engine.Telemetry.Supervisor`. It buffers, aggregates, and serves runtime
metrics for BO dashboards and optional remote benchmark sync.

---

## Data Flow

```
Business producers (Conversations, Ingestion workers)
  → Telemetry.record/4           ← allowlist filter: qa.*, feedback.*, ingestion.*
  → Buffer.enqueue/1             ← async GenServer cast
      → periodic flush (10s) or batch flush (200 points)
      → Repo.insert_all(Point)

AggregateRollupsWorker (Oban, queue: :telemetry)
  → reads cursor telemetry.rollup_point_id_cursor
  → groups raw points into 10-minute buckets
  → upserts Rollup rows
  → advances cursor

PushRollupsWorker (queue: :telemetry_remote, opt-in)
  → pushes local rollups to https://telemetry.zaq.ai

PullBenchmarksWorker (queue: :telemetry_remote, opt-in)
  → pulls cohort benchmark rollups from remote API
  → stores as source="benchmark" Rollup rows

PrunePointsWorker (queue: :telemetry)
  → deletes raw points older than telemetry.raw_retention_days (default 60)

DashboardData.load_dashboard/1
  → queries Rollup rows, builds standardized chart payloads
  → consumed by BO dashboard LiveViews
```

---

## Modules

### Telemetry Context (`Zaq.Engine.Telemetry`)
- Public API for telemetry recording and dashboard queries.
- `record/4` — enqueues a point asynchronously; allowlisted to `qa.*`, `feedback.*`,
  `ingestion.*` (always) and `repo.*`, `oban.*`, `phoenix.*` (only with `allow_infra: true`).
- `record_feedback/2` — records `feedback.rating` and optionally `feedback.negative.count`
  (when rating ≤ 2).
- `load_dashboard/1`, `load_chart/2` — standard dashboard/single-chart payloads.
- `load_llm_performance/1`, `load_conversations_metrics/1`,
  `load_knowledge_base_metrics/1`, `load_main_dashboard_metrics/1` — scoped dashboard loaders.
- `dashboard_kpis/1` — deprecated compatibility shim.
- `list_recent_points/1` — raw points for E2E/inspection; supports `*` wildcard on metric.
- `list_local_rollups_since/2` — rollup rows after a cursor for push sync.
- `upsert_benchmark_rollups/1` — stores benchmark rows with `source="benchmark"`.
- `telemetry_enabled?/0`, `benchmark_opt_in?/0`, `capture_infra_metrics?/0` — feature flags.
- `get_cursor/1`, `put_cursor/2` — read/write datetime cursors from `system_configs`.
- `get_cursor_id/1`, `put_cursor_id/2` — read/write integer cursors from `system_configs`.
- `organization_profile/0` — returns org cohort dimensions for benchmark cohorting.
- `dimension_key/1` — deterministic sorted key from a dimensions map.

### Telemetry Buffer (`Zaq.Engine.Telemetry.Buffer`)
- GenServer; async write buffer for telemetry points.
- `enqueue/1` — `cast` from callers; never blocks.
- `flush/0` — synchronous forced flush (used in tests and graceful shutdown).
- Auto-flushes every 10s or when batch reaches 200 points.
- `terminate/2` performs a best-effort final flush on graceful shutdown.

### Telemetry Collector (`Zaq.Engine.Telemetry.Collector`)
- GenServer; attaches to native `:telemetry` events at startup.
- Collected events: `[:phoenix, :router_dispatch, :stop/exception]`,
  `[:zaq, :repo, :query]`, `[:oban, :job, :stop/exception]`.
- Only persists infra metrics when `capture_infra_metrics` is enabled.
- Applies per-route and per-table noise filters.
- `reload_policy/0` — reloads collection thresholds from `system_configs` without restart.

### Telemetry Workers

- **`AggregateRollupsWorker`** — queue: `:telemetry`, max 5 attempts. Groups raw points
  into 10-minute buckets; cursor: `telemetry.rollup_point_id_cursor`; batch: 5,000 points.
- **`PushRollupsWorker`** — queue: `:telemetry_remote`, max 5 attempts. Pushes local
  rollups to remote benchmark API; cursor: `telemetry.push_cursor`. Only runs when
  benchmark sync is enabled.
- **`PullBenchmarksWorker`** — queue: `:telemetry_remote`, max 5 attempts. Pulls cohort
  benchmark rollups from remote API and stores them with `source="benchmark"`;
  cursor: `telemetry.pull_cursor`.
- **`PrunePointsWorker`** — queue: `:telemetry`, max 3 attempts. Deletes raw points older
  than `telemetry.raw_retention_days` (default 60 days).

---

## Schemas

**`Zaq.Engine.Telemetry.Point`** (`telemetry_points`)
- Fields: `metric_key`, `occurred_at`, `value` (float), `dimensions`, `dimension_key`,
  `source`, `node`.
- Append-only; no `updated_at`.

**`Zaq.Engine.Telemetry.Rollup`** (`telemetry_rollups`)
- Fields: `metric_key`, `bucket_start`, `bucket_size`, `source`, `dimensions`,
  `dimension_key`, `value_sum`, `value_count`, `value_min`, `value_max`,
  `last_value`, `last_at`.
- Unique constraint: `(metric_key, bucket_start, bucket_size, source, dimension_key)`.

---

## Dashboard Contracts

Dashboard payloads are typed via contract structs under
`Zaq.Engine.Telemetry.Contracts`:

| Struct | Used for |
|---|---|
| `DashboardChart` | Envelope for every chart payload |
| `DisplayMeta` | Visible metadata (title, subtitle, unit, etc.) |
| `RuntimeMeta` | Runtime metadata (alerts, thresholds, SLA) |
| `ScalarPayload` | Single metric card / gauge |
| `ScalarListPayload` | Grid of metric cards |
| `SeriesPayload` | Time-series chart |
| `CategoryVectorPayload` | Bar, donut, radar charts |
| `StatusListPayload` | Status grid |
| `ProgressPayload` | Progress countdown |

---

## Files

```
lib/zaq/engine/telemetry/
├── benchmark_connector/
│   └── http.ex                   # HTTP client for remote benchmark API
├── contracts/
│   ├── dashboard_chart.ex        # Envelope contract for dashboard chart payloads
│   ├── display_meta.ex           # Visible metadata contract
│   ├── runtime_meta.ex           # Runtime metadata contract
│   └── payloads/
│       ├── category_vector_payload.ex  # Bar/donut/radar chart payload
│       ├── progress_payload.ex         # Progress countdown payload
│       ├── scalar_list_payload.ex      # Metric card grid payload
│       ├── scalar_payload.ex           # Single metric card payload
│       ├── series_payload.ex           # Time-series chart payload
│       └── status_list_payload.ex      # Status grid payload
├── workers/
│   ├── aggregate_rollups_worker.ex     # Oban: raw points → rollup buckets
│   ├── prune_points_worker.ex          # Oban: delete old raw points
│   ├── pull_benchmarks_worker.ex       # Oban: pull remote benchmark rollups
│   └── push_rollups_worker.ex          # Oban: push local rollups to remote API
├── benchmark_connector.ex        # BenchmarkConnector behaviour/wrapper
├── buffer.ex                     # GenServer: async telemetry write buffer
├── collector.ex                  # GenServer: native telemetry event collector
├── dashboard_data.ex             # Dashboard payload builder from rollups
├── point.ex                      # Ecto schema: telemetry_points table
├── rollup.ex                     # Ecto schema: telemetry_rollups table
└── supervisor.ex                 # Supervises Buffer + Collector
lib/zaq/engine/telemetry.ex       # Public API: record/4, dashboard loaders, cursors
```

---

## Configuration

System Config keys (managed at `/bo/system-config`):

| Key | Default | Description |
|---|---|---|
| `telemetry.enabled` | `true` | Enables telemetry point persistence |
| `telemetry.benchmark_opt_in` | `false` | Enables push/pull with remote benchmark API |
| `telemetry.capture_infra_metrics` | `false` | Enables Phoenix/Ecto/Oban metric collection |
| `telemetry.request_duration_threshold_ms` | `10` | Min Phoenix request duration to record |
| `telemetry.repo_query_duration_threshold_ms` | `5` | Min Repo query duration to record |
| `telemetry.raw_retention_days` | `60` | Days before raw points are pruned |
| `telemetry.remote_url` | `https://telemetry.zaq.ai` | Remote benchmark API URL |
| `telemetry.remote_token` | — | Remote API auth token |
| `telemetry.org_id` | — | Organisation ID for benchmark cohorting |
| `telemetry.org_size` | `"unknown"` | Organisation size for benchmark cohorting |
| `telemetry.geography` | `"unknown"` | Geography dimension for benchmark cohorting |
| `telemetry.industry` | `"unknown"` | Industry dimension for benchmark cohorting |
| `telemetry.rollup_point_id_cursor` | — | Cursor for AggregateRollupsWorker |
| `telemetry.push_cursor` | — | Cursor for PushRollupsWorker |
| `telemetry.pull_cursor` | — | Cursor for PullBenchmarksWorker |
| `telemetry.no_answer_alert_threshold_percent` | — | Alert threshold for conversations dashboard |
| `telemetry.conversation_response_sla_ms` | — | Response SLA for conversations dashboard |

Environment variable overrides: `TELEMETRY_REMOTE_URL` and `TELEMETRY_REMOTE_TOKEN`
take precedence over system config values.

Oban queues:

- `:telemetry` — rollup aggregation and point pruning
- `:telemetry_remote` — push/pull with remote benchmark API

---

## Metric Naming Conventions

`Zaq.Engine.Telemetry.record/4` persists metrics by prefix allowlist:

- business metrics (always allowed): `qa.*`, `feedback.*`, `ingestion.*`
- infrastructure metrics (opt-in only): `repo.*`, `oban.*`, `phoenix.*`

Notes:

- infra metrics are persisted only when callers pass `allow_infra: true`
- unknown prefixes are intentionally ignored
- keep metric keys lowercase, dot-separated, and domain-first (for example: `qa.answer.confidence`, `ingestion.documents.count`)

---

## Buffer Flush Behavior

`Zaq.Engine.Telemetry.Buffer` stores telemetry points in memory and flushes them
to `telemetry_points` using batched `Repo.insert_all/3` writes.

Flush triggers:

- periodic timer (`flush_interval_ms`, default 10s)
- batch size threshold (`max_batch_size`, default 200 points)
- explicit `Zaq.Engine.Telemetry.Buffer.flush/0`

Graceful shutdown behavior:

- the telemetry buffer process `terminate/2` callback performs a best-effort final flush

This improves persistence of in-flight telemetry points during graceful stop.

## Limitations

This is still an in-memory buffer. In cases like VM crash, OS kill (`SIGKILL`),
or power loss, points that have not been flushed yet can still be lost.

---

## Key Design Decisions

- **Telemetry Buffer is a GenServer** — callers `cast` points and never block; flush
  is periodic (10s) or threshold-based (200 points) with a best-effort final flush on
  shutdown.
- **Infra metrics are opt-in** — Phoenix/Ecto/Oban events are only persisted when
  `capture_infra_metrics` is `true`; noise filters exclude asset routes and telemetry
  tables themselves.
- **Rollup cursors in system_configs** — workers advance named cursors atomically so
  aggregation is resumable after restarts.
