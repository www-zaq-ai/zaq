# Person and channel identity normalization

## Scope

Normal Ecto migration runs apply
`20260910153017_add_person_merge_aliases.exs` before
`20260910194115_normalize_person_emails.exs`. The latter automatically normalizes
stored emails and merges each connected identity component into its lowest-ID Person
using the [canonical merge contract](../services/engine.md#person-merges-and-historical-identities).
Nonblank `Person.email` and email-channel identifiers share one trim/lowercase key.
Other platforms use exact identifiers. Narrow projections and a star-edge graph
handle transitive components without pairwise scans. Singletons deduplicate existing
channels on every platform, retaining the lowest channel ID and weight, filling
missing metadata and keeping latest activity. Blank Person emails add no identity
edges. Blank legacy channel identifiers **abort with the channel ID**; an operator
must correct them rather than silently merge or discard them.

Before merging a component, the migration snapshots all source profile emails.
After merging, it adds each distinct canonical nonblank email missing from the
survivor's email channels. This preserves discovery by losing profile emails even
when the connection was solely Telegram or another platform. Primary-email precedence
and existing channel metadata/activity stay intact; new identity channels have no
interaction timestamp. Added identities roll back with the rest of the migration.

After cleanup executes via `flush/0`, the same data migration replaces
`channels_person_id_platform_channel_identifier_index` with global unique
`channels_platform_channel_identifier_index` on `(platform, channel_identifier)`.
Cleanup, index replacement and the data migration ledger entry commit atomically.
Successful application is recorded in Ecto's ledger, so subsequent runs skip it.
The old index remains active throughout cleanup. An unexpected violation raises
`Ecto.ConstraintError` and rolls back the migration; runtime changesets declare only
the global index and do not map legacy constraint errors.

## Deploy

1. Take a restorable database backup before normalization.
   For example: `pg_dump --format=custom --file=before-person-identity.dump "$DATABASE_URL"`.
2. Pause **all application writers across nodes**, including channels, agents,
   schedulers and workers. Keep them quiesced until migration success; database
   locks do not replace this pause.
3. With the new release installed, run the normal release migration command:
   `bin/zaq eval 'Zaq.Release.migrate()'`. It applies the alias schema first and
   runs normalization with Repo only, before starting the full application.
   If deployment runs migrations automatically before startup, this data migration
   is included: complete the backup and writer pause before that deployment step.
4. Confirm both migration versions completed successfully, then restart nodes and
   resume writers.

The migration takes the merger advisory lock before write-blocking locks on `people`
and `channels`; index creation is transactional, not concurrent. Budget a maintenance
window for the graph, relationship transfers and index build. Do not run a schema-only
global index creation ahead of cleanup.

## Failure and rollback

A validation failure raises and rolls back the entire data migration, including
earlier collision groups, index changes and its ledger entry. The preceding alias schema migration
remains applied. Keep writers paused, correct the invalid legacy data, and rerun
the normal migration command.

Completed Person merges are **irreversible**: the data migration's `down/0` raises.
To recover pre-merge identities and conflicting values, keep writers paused and
restore the pre-migration database backup with the matching application release.
Removing alias/history columns does not restore merged data.

## Reproduce migration validation

From the repository root, run the Repo-only replay against its disposable test
database (created and dropped by the script):

```sh
MIX_ENV=test MIX_TEST_PARTITION=_person_alias_replay mix run --no-start test/support/person_alias_migration_replay.exs
```

It verifies fresh schema migration, mixed email/telegram transitive grouping,
discovery through retained profile emails, failed-merge data/channel/index/ledger rollback,
global uniqueness, retry, and an
already-applied rerun without starting the ZAQ application.

For normal tests against the amended sequence, use a fresh disposable test partition:

```sh
MIX_TEST_PARTITION=_channel_identity mix test test/zaq/accounts
MIX_TEST_PARTITION=_channel_identity npm --prefix test/e2e run test:journeys -- people.spec.js
```

Choose a new partition suffix if that disposable database already recorded an older
version of this unapplied-in-release sequence. No user/development database reset or
ledger deletion is required. Legacy fixtures use serial sandbox transactions with
transactional index removal/restoration; the standalone replay verifies real commits
and rollbacks in its own guarded disposable database.
