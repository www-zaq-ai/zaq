# Native PostgreSQL CI performance investigation — 2026-09-27

## Scope and provenance

This is a read-only production investigation at local `main` SHA `37490b138fd58a6655be8a7a81972be8e9c32ab7`. The main worktree was clean before the investigation. Its latest `main` Elixir CI run remained [36205553154](https://github.com/www-zaq-ai/zaq/actions/runs/36205553154), with native job [108301211989](https://github.com/www-zaq-ai/zaq/actions/runs/36205553154/job/108301211989). A later PR run, [36271778103](https://github.com/www-zaq-ai/zaq/actions/runs/36271778103), used SHA `23e7fd14` and added retrieval work; its 14m52s native job and 678.6s covered ExUnit phase are **uncontrolled context**, not a new `main` baseline.

The checkout's `.git/worktrees` directory was not writable in this sandbox, so `git worktree add` failed. Experiments instead ran in a disposable local shared clone under `/private/tmp`, at the same SHA, with copied dependency/build artifacts and a separate `zaq_test_ci_perf` database. The only temporary code was a lightweight ExUnit formatter and an environment-gated bcrypt setting in that clone's `test_helper.exs`; no production source, assertions, test IDs, or property counts were edited. The Python crawler files were restored into the clone before valid full-suite comparisons; the first exploratory run had one missing-file failure and is excluded from paired results.

Effective local tools: Elixir/Mix 1.19.5, OTP 28.1 (`erts-16.1`), Git 2.42.0, PostgreSQL 16.14 with pgvector 0.8.2, Python 3.13.0, `uv` 0.10.9, `bw` 0.13.3, `gh` 2.92.0, Docker server 24.0.6, Context Mode 1.0.169, and working Serena Elixir navigation (Serena version not exposed). Context Mode's Codex hooks/feature flag are missing, although execution and search work. Direct `sysctl` CPU queries were sandbox-blocked; Python reports 12 logical CPUs. CI reported OTP 28/Elixir 1.19.5 with four BEAM schedulers, `max_cases: 8`, and a PostgreSQL 18 service. Local A/B runs used the **same local hardware, runtime, database service, seed 12345, and `max_cases: 8`** on both sides; local-to-CI timings are not controlled comparisons.

No matching Beadwork performance issue was found in the existing issue list. Action reuse: not applicable — this investigation does not add or change an executable operation.

## Current `main` native job breakdown

The successful job ran 14m24s (864s). GitHub step timestamps are rounded to seconds; figures below are approximate and sum with small boundary/cleanup differences. ExUnit's own timing comes from the job log.

| Phase | Observed time | Evidence/meaning |
| --- | ---: | --- |
| Runner and PostgreSQL service setup, checkout | ~26s | Job setup, container health, checkout |
| Elixir toolchain setup | ~7s | OTP/Elixir installation |
| Dependency cache/install and compilation | ~33s | Cache 6s, `mix deps.get` 3s, forced dependency/LiveView compile 24s |
| Python fetch, venv and pip | ~41s | Fetch 4s; Python setup/cache negligible; fresh venv and install 37s |
| Database preparation | ~13s | Extension provision 3s, installation verification 10s |
| App/test loading and coverage startup | ~36s | `mix coveralls.github` start to ExUnit seed announcement |
| ExUnit execution under coverage | **693.6s** | 163.7s async + **529.9s sync**; 48 doctests, 178 properties, 9,741 tests, 0 failures, 1 skipped, 87 excluded |
| Coverage finalization/upload | ~7s | ExUnit finish to successful Coveralls upload |
| Other runner boundaries/cleanup | ~8s | Step rounding, post-actions, container stop |

The covered CI command's 736s includes the 36s pre-ExUnit phase and ~7s finalization. It does **not** show how much slower individual tests become under coverage; that requires same-machine plain/covered runs below. Python and database setup are real CI costs, but the covered ExUnit phase dominates the job.

## Measurement method and plain whole-suite result

The temporary formatter recorded `:module_started`, `:module_finished`, and `:test_finished` events without `--slowest`, `--slowest-modules`, or trace. ExUnit retained normal scheduling and `max_cases: 8`. Module wall time contains test bodies, per-test setup, `setup_all`, on-exit cleanup, and runner gaps. ExUnit's `test.time` contains per-test setup and body but excludes on-exit callbacks; module wall minus summed test time is a **residual**, not a pure teardown measurement. Module times overlap for async modules and must never be summed as wall-clock savings.

The passing full plain baseline took **526.74s ExUnit / 532.76s process wall** (56.39s async, 470.35s sync). The passing full plain `log_rounds: 4` run took **273.74s ExUnit / 279.28s wall** (52.51s async, 221.23s sync): **253.00s ExUnit and 253.48s wall saved, about 48%**. Each loaded 670 modules and emitted 10,054 test events, including excluded/skipped cases; the existing Python crawler test passed. One earlier cost-4 full run completed in 277.03s ExUnit but failed a timing-sensitive telemetry ownership assertion; its isolated test passed and the repeat full run passed. This failure is recorded under blockers rather than discarded.

Eight hash-plus-verify operations averaged 467.4ms each at effective default cost 12 and 1.91ms at cost 4 on the same machine; produced hashes carried `$2b$12$` and `$2b$04$` prefixes, and every verification succeeded. The fixed-seed 53-test Accounts cohort measured 7.79s versus 0.60s of ExUnit run time. The project does not set a bcrypt test cost today: `Bcrypt.hash_pwd_salt/2` defaults to 12, `User.hash_password/1` invokes it, and `Bcrypt.no_user_verify/1` also hashes. Existing Accounts tests assert real hash verification, valid/invalid authentication, and missing-user outcomes.

The 670 profiled modules comprise 433 async, 222 explicitly sync, and 15 implicitly sync modules. Their baseline serial module wall sum was 470.55s, close to ExUnit's 470.35s sync phase. The remaining async module wall overlaps. Across all modules, the measured residual outside `test.time` summed to ~52.9s; the largest were ProviderModels 17.8s (LLMDB reload in `on_exit`), ServerManager 9.75s, CommunicationBridge 6.26s (global module recompile/restore), and ZAQRouter 3.89s. This residual includes `setup_all`, teardown and scheduling, so it is an investigation lead rather than an attributable saving.

### Top 20 modules in the passing plain baseline

`A` = async, `S` = explicit sync, `I` = implicit sync. Times are module wall seconds, with normal concurrency. The top sync modules are ranked separately below.

| Rank | Module | Mode | Wall s | Residual s |
| ---: | --- | :---: | ---: | ---: |
| 1 | `ZaqWeb.Live.BO.System.SystemConfigLiveTest` | S | 56.28 | 0.63 |
| 2 | `ZaqWeb.Live.BO.AI.IngestionLiveTest` | S | 54.49 | 1.23 |
| 3 | `Zaq.Agent.ProviderModelsTest` | A | 36.94 | 17.80 |
| 4 | `ZaqWeb.Live.BO.System.PeopleLiveTest` | A | 27.06 | 0.03 |
| 5 | `ZaqWeb.Live.BO.AI.SkillsLiveTest` | I | 26.76 | 0.24 |
| 6 | `ZaqWeb.Live.BO.Communication.ChatLiveTest` | I | 24.23 | 0.16 |
| 7 | `Zaq.People.AuthRateLimiterPeerTest` | S | 21.41 | 0.00 |
| 8 | `Zaq.Agent.ExecutorIntegrationTest` | S | 19.91 | 0.07 |
| 9 | `ZaqWeb.Live.BO.AI.AgentsLiveTest` | I | 17.78 | 0.01 |
| 10 | `ZaqWeb.Live.BO.AI.WorkflowRunLiveTest` | A | 17.44 | 0.01 |
| 11 | `ZaqWeb.Live.BO.AI.WorkflowDetailLiveTest` | A | 17.41 | 0.02 |
| 12 | `ZaqWeb.Live.BO.AI.WorkflowsLiveTest` | A | 17.33 | 0.01 |
| 13 | `ZaqWeb.Live.BO.Communication.ChannelsLiveTest` | I | 16.47 | 0.07 |
| 14 | `ZaqWeb.Live.BO.Communication.HistoryLiveTest` | A | 16.08 | 0.01 |
| 15 | `Zaq.Channels.CommunicationBridgeTest` | S | 14.63 | 6.26 |
| 16 | `Zaq.Agent.ServerManagerTest` | S | 11.00 | 9.75 |
| 17 | `Zaq.Agent.ZAQRouterTest` | S | 10.92 | 3.89 |
| 18 | `Zaq.System.MachineSignalsTest` | S | 9.47 | 0.06 |
| 19 | `ZaqWeb.Live.BO.Communication.ConversationDetailLiveTest` | A | 8.31 | 0.01 |
| 20 | `Zaq.Channels.PersonCredentialIngressIntegrationTest` | S | 7.95 | 0.06 |

### Top 20 individual tests

`test.time` includes per-test setup and body, excludes `on_exit`. File/line locations are at the recorded SHA.

| Rank | Test (module and short name) | File:line | s |
| ---: | --- | --- | ---: |
| 1 | `AuthRateLimiterPeerTest` — actual Application startup gates Channels subtree | `test/zaq/people/auth_rate_limiter_peer_test.exs:8` | 18.34 |
| 2 | `UpdateBadgeWorkerTest` — GitHub failure preserves badge | `test/zaq/system/update_badge_worker_test.exs:64` | 6.56 |
| 3 | `MattermostAdminTest` — transport error reason | `test/zaq/channels/mattermost_admin_test.exs:39` | 6.55 |
| 4 | `ExecutorIntegrationTest` — credential mutation fences runtime | `test/zaq/agent/executor_integration_test.exs:376` | 6.12 |
| 5 | `ImapAdapterTest` — silent/closed fake server errors | `test/zaq/channels/email_bridge/imap_adapter_test.exs:701` | 5.00 |
| 6 | `ExecutorIntegrationTest` — selected authentication sent to LLM | `test/zaq/agent/executor_integration_test.exs:248` | 4.63 |
| 7 | `ProviderModelsTest` — injected ZAQ Router model with endpoint/key | `test/zaq/agent/provider_models_test.exs:248` | 3.98 |
| 8 | `ProviderModelsTest` — catalog with API key | `test/zaq/agent/provider_models_test.exs:260` | 3.72 |
| 9 | `ProviderModelsTest` — no models without key | `test/zaq/agent/provider_models_test.exs:232` | 3.56 |
| 10 | `ProviderModelsTest` — OAuth model list without key | `test/zaq/agent/provider_models_test.exs:279` | 3.48 |
| 11 | `ExecutorIntegrationTest` — natural auth-expiry timer | `test/zaq/agent/executor_integration_test.exs:813` | 3.44 |
| 12 | `ZAQRouterTest` — second reload replaces catalog | `test/zaq/agent/zaq_router_test.exs:30` | 3.43 |
| 13 | `PersonCredentialIngressIntegrationTest` — grant changes apply lazily | `test/zaq/channels/person_credential_ingress_integration_test.exs:294` | 3.35 |
| 14 | `PersonCredentialIngressIntegrationTest` — replacement/revocation fences runtime | `test/zaq/channels/person_credential_ingress_integration_test.exs:218` | 3.33 |
| 15 | `FilePreviewLiveTest` — XLS fallback without Python | `test/zaq_web/live/bo/ai/file_preview_live_test.exs:154` | 3.28 |
| 16 | `DocumentProcessorTest` — CSV to Markdown table | `test/zaq/ingestion/document_processor_test.exs:1456` | 2.96 |
| 17 | `FactoryToolTimeoutTest` — registration-order property | `test/zaq/agent/factory_tool_timeout_test.exs:21` | 2.74 |
| 18 | `ConversationDetailLiveTest` — mount back link | `test/zaq_web/live/bo/communication/conversation_detail_live_test.exs:76` | 2.60 |
| 19 | `MachineSignalsTest` — macOS output parsing | `test/zaq/system/machine_signals_test.exs:384` | 2.38 |
| 20 | `MachineSignalsTest` — macOS command-error tolerance | `test/zaq/system/machine_signals_test.exs:551` | 2.17 |

### Top 20 serial modules

Serial module times add into the sync phase; implicit sync modules are explicitly marked. A cost-4 full-suite profile is shown where useful because it changes the investment order.

| Sync rank | Module | Baseline s | Cost-4 s | Mode |
| ---: | --- | ---: | ---: | :---: |
| 1 | `SystemConfigLiveTest` | 56.28 | 6.48 | S |
| 2 | `IngestionLiveTest` | 54.49 | 8.32 | S |
| 3 | `SkillsLiveTest` | 26.76 | 4.95 | I |
| 4 | `ChatLiveTest` | 24.23 | 2.45 | I |
| 5 | `AuthRateLimiterPeerTest` | 21.41 | 21.34 | S |
| 6 | `ExecutorIntegrationTest` | 19.91 | 19.09 | S |
| 7 | `AgentsLiveTest` | 17.78 | 1.42 | I |
| 8 | `ChannelsLiveTest` | 16.47 | 1.55 | I |
| 9 | `CommunicationBridgeTest` | 14.63 | 14.47 | S |
| 10 | `ServerManagerTest` | 11.00 | 11.25 | S |
| 11 | `ZAQRouterTest` | 10.92 | 10.75 | S |
| 12 | `MachineSignalsTest` | 9.47 | 9.27 | S |
| 13 | `PersonCredentialIngressIntegrationTest` | 7.95 | 7.91 | S |
| 14 | `NotificationImapLiveTest` | 7.75 | 0.68 | I |
| 15 | `DashboardLiveTest` | 7.58 | 0.33 | I |
| 16 | `NotificationSmtpLiveTest` | 7.44 | 0.42 | I |
| 17 | `BrowsingTest` | 7.30 | 8.45 | S |
| 18 | `TriggersLiveTest` | 6.77 | 0.40 | S |
| 19 | `MattermostAdminTest` | 6.72 | 6.73 | S |
| 20 | `UpdateBadgeWorkerTest` | 6.57 | 6.57 | S |

The first four serial modules contributed 161.8s of baseline module wall and 22.2s at cost 4. Their 139.6s measured module-time reduction is a large part of the 253.0s suite saving. System Config creates a user in each test setup (`system_config_live_test.exs:77`), Ingestion a super admin (`ingestion_live_test.exs:326`), Skills a super admin (`skills_live_test.exs:25`), and Chat a user (`chat_live_test.exs:214`). These fixtures invoke real bcrypt hashing; their setup differences are measured, while the exact hash-versus-other-setup split is inferred from the code and the controlled cost change.

## Plain versus covered execution on matching local runtime/hardware

All runs below used the same checkout, ExUnit seed, 8 cases, Elixir/OTP, Mac and PostgreSQL service. `mix coveralls` generated a local report without CI's network upload. Each full run selected the same 670 modules/10,054 test events and retained Python/property tests. Coverage was 97.1% in every covered run. A nonzero run still completed the suite and report, but is **not** validation success.

| Command/setting | ExUnit s | Process wall s | Result |
| --- | ---: | ---: | --- |
| `mix test`, default bcrypt | 526.74 | 532.76 | Pass |
| `mix coveralls`, default bcrypt, attempt 1 | 512.84 | 527.29 | Fail: async OAuth permission-grant deadlock |
| `mix coveralls`, default bcrypt, attempt 2 | 506.69 | 520.40 | Fail: telemetry owner-exit race |
| `mix test`, bcrypt cost 4 | 273.74 | 279.28 | Pass |
| `mix coveralls`, bcrypt cost 4 | 268.58 | 283.92 | Fail: same telemetry owner-exit race |

The paired **passing plain** runs establish a 253.00s ExUnit saving. The default-cost covered rerun and cost-4 covered run differ by 238.11s ExUnit / 236.48s process wall (~45%), but both failed one existing timing-sensitive test; this is supportive timing evidence, **not a passing covered A/B gate**. The telemetry failure also appeared in an earlier plain cost-4 attempt and passed in isolation. The OAuth deadlock occurred under default cost, passed in isolation, and has an async shared-write path. Neither failure is evidence that bcrypt output is incorrect; both require independent isolation work before CI changes can be accepted.

Covered execution's *outside-ExUnit* time was 13.7s on default cost and 15.3s at cost 4, versus 6.0s and 5.5s plain: about **8–10s extra startup/report work locally**. Individual covered ExUnit phases were 5–20s shorter than plain in these single runs, so test instrumentation overhead is **not resolved** by this noisy comparison; do not infer negative overhead or a coverage speedup. In current CI, the ~36s pre-ExUnit and ~7s post-ExUnit phases include coverage setup/upload, app/test loading and runner effects that cannot be separated further from that job alone. This is why plain CI ExUnit time must not be estimated by subtracting a guessed coverage percentage from 693.6s.

## Concurrency and ownership blockers

These are source findings, not claims that every cited test can be made async. Broad text counts are signals only: 119 test files mention `Application.put_env/delete_env` or `System.put_env/delete_env`, 24 mention sleeps, 24 process registration/name patterns, 17 ETS/persistent-term patterns, and seven global-Mox patterns. Individual tests need contract review before changing mode.

| Blocker | Concrete evidence | Implication |
| --- | --- | --- |
| Mutable runtime config and propagation | `test/zaq_web/live/bo/ai/ingestion_live_test.exs:373-422`, `test/zaq_web/live/bo/ai/skills_live_test.exs:51-57`, `test/zaq_web/live/bo/communication/chat_live_test.exs:221-246`; `test/zaq_web/controllers/person_session_controller_test.exs:702-705` changes `ROLES` through System env. Current policy requires per-call `Zaq.Config` overrides when possible. | These sync/implicit-sync modules cannot be flipped wholesale to async; BO route tests must propagate injected config through dispatch and spawned processes. |
| Global EventRegistry name and PubSub | `test/support/data_case.ex:26-29,67-85` unregisters/restores one VM-wide name for every DataCase test; `lib/zaq/engine/workflows.ex:1501-1508` checks it directly. `EventRegistry` already accepts `name:` and a `server` argument (`event_registry.ex:31-56`) but subscribes to a fixed PubSub topic (`:60-61`). | Reuse the existing server seam; audit Workflows callers and test scope before replacing the global swap. Global name changes are a correctness and async blocker, not a measured first saving. |
| Telemetry Buffer and sandbox ownership | `test/support/data_case.ex:35-54` allows the shared Buffer under each owner and flushes it on exit; `Buffer` already accepts a server for `enqueue/flush` (`buffer.ex:31-49`). `BufferCollectorTest` also flushes the global buffer (`buffer_collector_test.exs:17-40`). | One full cost-4 run and one covered baseline run failed `LLMPerformanceFailureTest:12` with an exiting sandbox owner; the isolated test passed. Existing `zaq-hui` tracks ownership diagnosis. Test-local buffer ownership or quiescence needs proof before async work. |
| Global module/Mox/ETS state | `test/zaq/channels/communication_bridge_test.exs:202-278` purges, recompiles and restores `Zaq.Channels.Bridge` globally; `test/zaq/engine/workflows/finch_pool_contention_test.exs:25` selects global Mox mode; `test/zaq/channels/people_auth_rate_limiter_test.exs:128-137` mutates shared ETS; `test/zaq/agent/provider_models_test.exs:226-229` is async yet reloads shared LLMDB in setup/on-exit. | Serial isolation is justified for the module swap. ProviderModels' 36.9s module wall and 17.8s residual merit a separate state-ownership audit. Mox expectations should remain process-private where possible. |
| Unboxed writes and cleanup | `test/support/person_oauth.ex:17-20` grants `:everyone` permissions through real DB writes from async OAuth tests. A covered baseline run hit a PostgreSQL deadlock in `people_permission_grants` at `oauth_attempts_test.exs:604`; that test passed alone. | Audit ownership and unique keys before adding concurrency or DB shards; a passing isolated test does not prove suite isolation. |
| Fixed values, paths and ports | Top LiveView setups use fixed usernames (`ingestion_live_test.exs:326`, `system_config_live_test.exs:77`, `chat_live_test.exs:214`); `config/test.exs:47-50` fixes server port 4002 for E2E; several test modules operate on file paths or process names. | Per-test values, temp paths and ports need an inventory before sharing one runner across partitions. Separate runners provide a stronger boundary. |
| Sleeps, polling and retries | The 18.34s peer-startup test (`auth_rate_limiter_peer_test.exs:8`), 6.56s badge failure (`update_badge_worker_test.exs:64`), 6.55s Mattermost transport failure (`mattermost_admin_test.exs:39`), and 5.00s IMAP error (`imap_adapter_test.exs:701`) are the longest single tests. | Preserve real timeout/retry behavior and assertions. Investigate test fakes or observable completion before claiming a saving; elapsed time can itself be the contract. |
| Expensive fixtures/hashing | `test/support/fixtures/accounts_fixtures.ex:25-40` creates users through `Accounts.create_user`; `lib/zaq/accounts/user.ex:93-100` hashes with bcrypt. The first four serial LiveView modules alone saved 139.6s of module time at test cost 4. | This is the only candidate with a passing whole-suite A/B saving and a small test-only scope. |

## Two- and four-shard assessment

Mix 1.19 sorts matching test files and assigns them round-robin by file index, not measured duration. The model below used those exact 668 file names and observed module wall times, then summed serial modules assigned to each shard. The final column is an **idealized execution floor**, `serial sum + max(async sum / 8, longest async module)`, using unchanged per-module times. It is **not** an observed shard run or a CI saving; scheduling, DB contention, duplicated setup, and coverage work can raise it.

| Profile | Shards | Files per shard | Serial seconds by shard | Model floor for slowest shard |
| --- | ---: | ---: | --- | ---: |
| Default bcrypt | 2 | 334 | 329 / 141 | ~347s |
| Default bcrypt | 4 | 167 | 84 / 84 / 246 / 57 | ~263s |
| Test bcrypt 4 | 2 | 334 | 138 / 84 | ~142s |
| Test bcrypt 4 | 4 | 167 | 52 / 34 / 86 / 50 | ~89s |

Equal file counts conceal severe default-cost imbalance. In the original post-bcrypt profile, before candidate 2, the 36.2s async ProviderModels module and 21.3s serial peer-rate-limiter module remained long indivisible units. The model suggests a *possible* post-bcrypt upper bound of ~132s additional saving with two shards or ~185s with four versus the 273.7s local suite; these are optimistic estimates, not promises. Candidate 2 has since changed the module timings, so this shard model needs a fresh profile before use. A balanced manifest based on updated covered timings may outperform default round-robin, but would need maintenance as tests change.

`config/test.exs:15-36` derives separate database names from `MIX_TEST_PARTITION`, but that variable alone does not isolate a PostgreSQL service, fixed port, shared filesystem, Python environment, global artifact path, or coverage upload. A CI pilot should use separate runners/services and per-shard artifacts. Mix and ExCoveralls support `.coverdata` export/import, but the current single `mix coveralls.github` command uploads one suite's report; posting four partial reports would break the coverage contract. Aggregate all shard artifacts once, verify source-line totals and exclusions against the existing report, then upload one result. The pilot must retain native Python tests, ParadeDB/optional jobs, property tests and current required checks.

## Candidate PR ranking

Line locations are snapshot references at `37490b138` and may drift. Module-time reductions overlap across async modules; they are not additive wall-clock savings. An “estimate” below is explicitly unmeasured.

| Rank/candidate | Files/lines | Measured contribution | Saving | Risk and dependencies | Smallest PR scope |
| --- | --- | --- | --- | --- | --- |
| **1. Test-only bcrypt cost 4 — done** | `config/test.exs:14-36`; `lib/zaq/accounts/user.ex:93-100`; `test/support/fixtures/accounts_fixtures.ex:25-40` | 470.35s plain sync phase at default cost; top four serial fixture modules 161.8s → 22.2s | **Measured 253.0s ExUnit / 253.5s wall (48%)** in passing full plain A/B. Covered timing suggests ~238s but both covered runs failed unrelated ownership tests. | Low implementation risk; verify real bcrypt output, missing-user path, and native covered CI pass. Production cost remains default 12. | Landed as `8a95ad58f`; test-only bcrypt cost 4. |
| **2. ProviderModels shared LLMDB fixture — done** | `test/zaq/agent/provider_models_test.exs:2,225-229`; `test/zaq/agent/zaq_router_test.exs:1-35` | Original profile: 36.9s async module; 17.8s residual, still 36.2s/18.2s at cost 4 | **Measured 12.8s whole-suite ExUnit saving** after candidate 1: 274.3s → 261.5s. Async fell 29.3s; sync rose 16.5s. | Shared LLMDB reloads were removed from async auth tests; real catalog integration remains in the synchronous router module. | Landed as `0065e1bab`; per-call adapter isolation and synchronous integration coverage. |
| 3. Serial BO test isolation | `test/zaq_web/live/bo/system/system_config_live_test.exs:2,77`; `test/zaq_web/live/bo/ai/ingestion_live_test.exs:2,326,373-422`; `test/zaq_web/live/bo/ai/skills_live_test.exs:2,51-57`; `test/zaq_web/live/bo/communication/chat_live_test.exs:2,214-246` | First four serial modules 161.8s before bcrypt, **22.2s after** | **Estimate: at most ~22s** from overlapping those four after PR 1, before contention; unmeasured. | High: mutable config, fixed identities, file effects, process propagation. Requires per-call `Zaq.Config`/event opts and test isolation audit. | One module or one isolated concern per PR; keep global-behavior scenarios sync. |
| 4. Long waits/retry tests | `test/zaq/people/auth_rate_limiter_peer_test.exs:8`; `test/zaq/system/update_badge_worker_test.exs:64`; `test/zaq/channels/mattermost_admin_test.exs:39`; `test/zaq/channels/email_bridge/imap_adapter_test.exs:701` | Four tests total ~36.5s of recorded setup/body, mostly sync | **Estimate unknown** until timing contract and retry path are traced. | Medium/high: tests may intentionally prove real timeout behavior; production timeouts and assertions must stay intact. | One collaborator/timer seam or event-based test cleanup with before/after timings. |
| 5. Two/four native shards | `.github/workflows/elixir-ci.yml:77-174`; `config/test.exs:15-36`; `mix.exs:27` | Post-bcrypt serial allocation 138/84s (2) or 52/34/86/50s (4) | **Idealized estimate ceiling:** ~132s (2) or ~185s (4) additional local test-phase saving; no shard run. | High CI/reliability cost: separate services, resource paths, balanced assignment, `.coverdata` aggregation and single Coveralls upload; more runner minutes. | Separate CI pilot PR with 2 shards and coverage equivalence proof before considering 4. |
| 6. Dependency/Python setup tuning | `.github/workflows/elixir-ci.yml:103-151` | ~33s dependency restore/compile, ~41s Python fetch/install, ~13s DB prep | **Estimate unknown**; 87s is total phase cost, not available saving. | Cache invalidation, Python pinning and extension verification must remain. | Benchmark one cache/compile change with cold and warm CI runs. |
| 7. EventRegistry/Buffer ownership | `test/support/data_case.ex:26-85`; `lib/zaq/engine/workflows.ex:1501-1508`; `lib/zaq/engine/event_registry.ex:31-56`; `lib/zaq/engine/telemetry/buffer.ex:31-49` | No attributable saving measured; two classes of full-suite failures expose correctness risk | **Estimate unknown**. | High: global names, PubSub and sandbox lifetime; existing `zaq-hui` diagnosis is a prerequisite. | Focused ownership/registration test-support PR, using existing `server` seams where contracts permit. |

### Original first PR recommendation — completed

Add `config :bcrypt_elixir, log_rounds: 4` **only in `config/test.exs`** and assert the effective test hash work factor while retaining the existing real `Bcrypt.verify_pass` assertions. This is the smallest measured high-impact change. It changes no production source, production work factor, security contract, timeout, or Python/coverage test selection. The local passing full-suite A/B saved 253s; CI saving remains an estimate until measured on its four-scheduler PostgreSQL 18 runner.

Acceptance checks for that PR:

1. Verify generated test hashes use cost 4 and still pass real correct/wrong-password and missing-user checks; confirm non-test configuration still uses the dependency default cost 12.
2. Run focused Accounts/BO-auth tests, `mix q`, the existing native covered CI job including crawler Python and all property tests, plus the other existing required jobs. Keep test IDs, assertions, coverage lines and exclusions stable. Require a passing `mix coveralls.github` on CI; the local covered attempts here do **not** satisfy that gate.
3. Compare at least two native CI runs on the same runner class against the recorded 693.6s ExUnit/14m24s job, identifying cache and runner variation rather than promising the local 48% transfers exactly. Diagnose any owner-exit/deadlock recurrence separately, including existing `zaq-hui`.
4. Follow the repository's final `mix precommit` gate before requesting human approval. No new feature E2E is indicated by this test-only setting; existing required checks remain in force.

Candidates 1 and 2 are complete. The post-bcrypt full-suite comparison supplied for candidate 2 used 274.3s (56.0s async, 218.3s sync) before isolation and 261.5s (26.7s async, 234.8s sync) after it. These are ExUnit times, not process wall or native CI measurements; the original estimates and shard model above remain historical evidence.

Remaining candidates are conditional: isolate one BO module only after its global config/identity contract is mapped; fix EventRegistry/Buffer ownership before broad async or shared-runner changes; pilot two shards only when separate resources and merged coverage are proven. Four shards should follow only if measured two-shard balance, wall time and runner cost justify them.

## Validation and limits

This investigation changed only this report in the main checkout. The passing plain A/B runs preserved the full local test selection and real Python test. Covered local commands generated reports but exited nonzero on pre-existing timing-sensitive database ownership/deadlock paths; no test was skipped, weakened or removed to make them pass. The local database was PostgreSQL 16 rather than CI's PostgreSQL 18, and the local host has 12 logical CPUs versus the CI BEAM's four schedulers. Shard timings are modeled, not run. No commit, push or PR was made.
