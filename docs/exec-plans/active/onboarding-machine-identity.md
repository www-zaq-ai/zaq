# Onboarding Machine Signals — Implementation Plan

Status: ACTIVE
Owner: Jad
Created: 2026-06-11
Supersedes: previous draft (fingerprint-based approach, Dockerfile entrypoint — both dropped)

## Problem

Onboarding grants each new install free credits (~$2). Today the dedupe key is a single
`machine_fingerprint` derived from `/etc/machine-id` with an install-id fallback — both
trivially resettable. An abuser recreates the container and farms $2 per run.

## Approach

Replace the single fingerprint with a **signal map**: collect every available machine
detail at runtime and forward the map to the Portal. The Portal owns deduplication and
trust scoring — ZAQ's job is to collect faithfully and send honestly.

**Key decisions:**

1. **No `machine_fingerprint` field.** The Portal derives its own deduplication keys from
   the signals it receives. The existing `machine_fingerprint` field is removed from the
   onboarding payload.
2. **No Dockerfile changes.** The image is built on GitHub CI — any entrypoint that reads
   machine details at container startup captures the CI runner's hardware, not the
   customer's. All probes run at runtime inside the live application process.
3. **Nil is acceptable.** Docker containers, restricted environments, and ARM/macOS dev
   machines will produce nils for many fields. Signal keys whose source is unreadable are
   omitted from the map entirely. The Portal handles sparse payloads.
4. **One-time send.** Signals ride the existing `POST /onboarding` payload. No heartbeats,
   no recurring traffic.
5. **ZAQ OSS never blocks.** Portal conclusions affect credit grants only. The install
   runs regardless.

## Signals catalog

All probed at runtime by an unprivileged process. Nil/unreadable → key omitted.

### Identity

| Signal key | Source | Readable unprivileged? | Notes |
|---|---|---|---|
| `machine_id` | `/etc/machine-id` | Yes | World-readable on Linux |
| `product_uuid` | `/sys/class/dmi/id/product_uuid` | Root-only (0400) | Nil on Docker; real on bare-metal/VM if running as root |
| `board_serial` | `/sys/class/dmi/id/board_serial` | Root-only (0400) | Same |
| `chassis_serial` | `/sys/class/dmi/id/chassis_serial` | Root-only (0400) | Same |
| `boot_id` | `/proc/sys/kernel/random/boot_id` | Yes | Per host boot; survives container stop/start |

### Motherboard / hardware platform

| Signal key | Source | Readable unprivileged? |
|---|---|---|
| `sys_vendor` | `/sys/class/dmi/id/sys_vendor` | Yes (world-readable) |
| `product_name` | `/sys/class/dmi/id/product_name` | Yes |
| `board_vendor` | `/sys/class/dmi/id/board_vendor` | Yes |
| `board_name` | `/sys/class/dmi/id/board_name` | Yes |
| `chassis_type` | `/sys/class/dmi/id/chassis_type` | Yes |

### CPU

| Signal key | Source | Notes |
|---|---|---|
| `cpu_model` | `/proc/cpuinfo` `model name` (first entry) | Host value visible in containers |
| `cpu_cores` | `/proc/cpuinfo` `cpu cores` count | |
| `cpu_arch` | `uname -m` | |

### RAM

| Signal key | Source | Notes |
|---|---|---|
| `ram_total_gib` | `/proc/meminfo` `MemTotal` bucketed to nearest GiB | Host value visible in containers |

### GPU

| Signal key | Source | Notes |
|---|---|---|
| `gpu_vendor` | `/sys/bus/pci/devices/*/vendor` where `class` starts with `0x03` (display) | World-readable; nil if no PCI bus (ARM Docker Desktop) |
| `gpu_device` | `/sys/bus/pci/devices/*/device` (same filter) | |
| `gpu_model` | `/sys/bus/pci/devices/*/label` or DRM subsystem name if available | Best-effort |

### Network — MAC addresses

Collected as a list of `{interface, mac}` pairs. Excludes loopback (`lo`) and virtual
bridges. Docker bridge containers get a container-scoped virtual MAC on `eth0` — unstable
across recreations, but still useful as one signal among many. Host-network and bare-metal
installs expose real hardware MACs.

| Signal key | Source | Notes |
|---|---|---|
| `net_interfaces` | `/sys/class/net/*/address` + interface name | World-readable |
| `bluetooth_addresses` | `/sys/class/bluetooth/*/address` | World-readable where BT adapter exposed; nil otherwise |

### OS / runtime

| Signal key | Source |
|---|---|
| `kernel_version` | `uname -r` |
| `os_id` | `/etc/os-release` `ID=` field |
| `os_version` | `/etc/os-release` `VERSION_ID=` field |
| `hostname` | `:inet.gethostname/0` |
| `is_docker` | `/.dockerenv` exists or `/proc/1/cgroup` contains `docker`/`containerd` |
| `cgroup_v2` | `/sys/fs/cgroup/cgroup.controllers` exists |

### Cloud attestation (strongest — optional)

Fetched from the instance metadata endpoint, forwarded raw, signature-verified by the
Portal. Cannot be faked without paying for a new cloud instance. Silently skipped when
unreachable (non-cloud, firewall, hop-limit).

| Signal key | Provider | Notes |
|---|---|---|
| `aws_attestation` | AWS IMDSv2 — PUT token then GET identity doc | Default hop-limit=1 blocks bridge containers; doc says increase to 2 |
| `gcp_attestation` | GCP metadata `instance/service-accounts/default/identity` | Requires `Metadata-Flavor: Google` header |
| `azure_attestation` | Azure IMDS attested data | Requires `Metadata: true` header |

## Wire format

Each signal value is hashed individually before transmission. Raw values never leave the
machine (attestation documents are the explicit exception — the Portal must verify their
signatures).

```
hash(name, value) = sha256("zaq-signal-v1:" <> name <> ":" <> normalize(value))
                    |> hex |> first 32 chars
```

`normalize/1`: trim whitespace, lowercase, collapse internal runs of whitespace to a single
space. Must be byte-identical with the Portal's server-side recomputation — pin with shared
test vectors (fixture file copied to both repos).

`net_interfaces` and `bluetooth_addresses` are lists; each element hashed independently,
list sent as `[hash, hash, …]`.

Attestation documents are sent raw (not hashed) — the Portal verifies the provider
signature over the plaintext claims.

```json
{
  "machine_signals": {
    "version": 1,
    "identity": {
      "machine_id": "ef56…",
      "product_uuid": "ab12…",
      "board_serial": "cd34…",
      "chassis_serial": "7a8b…",
      "boot_id": "8f7e…"
    },
    "motherboard": {
      "sys_vendor": "2e1f…",
      "product_name": "0a9b…",
      "board_vendor": "1c0d…",
      "board_name": "3f2e…",
      "chassis_type": "9b8a…"
    },
    "cpu": {
      "model": "5d4c…",
      "cores": "7e6d…",
      "arch": "1a2b…"
    },
    "ram": {
      "total_gib": "4c3b…"
    },
    "gpu": [
      { "vendor": "9a8f…", "device": "7c6e…" }
    ],
    "network": {
      "interfaces": ["ab12…", "cd34…"],
      "bluetooth": ["ef56…"]
    },
    "os": {
      "kernel": "3b2a…",
      "id": "1d0c…",
      "version": "5f4e…",
      "hostname": "7b6a…",
      "is_docker": true,
      "cgroup_v2": true
    },
    "attestation": {
      "provider": "aws",
      "document": "<raw signed doc>",
      "signature": "…"
    }
  }
}
```

Keys whose source is unreadable are omitted, never sent empty or null.

## Onboarding payload: before → after

### Before (current `client.ex:41-46`)

```json
{
  "email": "user@example.com",
  "machine_fingerprint": "zaq-machine-fingerprint-v1:abcdef1234...",
  "plan": "free",
  "network": {
    "user_agent": "ZaqApp/1.0.0 (linux)",
    "accept_lang": "en-US",
    "timezone_offset_minutes": 120
  }
}
```

### After

```json
{
  "email": "user@example.com",
  "plan": "free",
  "network": {
    "user_agent": "ZaqApp/1.0.0 (linux)",
    "accept_lang": "en-US",
    "timezone_offset_minutes": 120
  },
  "machine_signals": {
    "version": 1,
    "identity": {
      "machine_id": "ef56…",
      "boot_id": "8f7e…"
    },
    "motherboard": {
      "sys_vendor": "2e1f…",
      "product_name": "0a9b…"
    },
    "cpu": { "model": "5d4c…", "cores": "7e6d…", "arch": "1a2b…" },
    "ram": { "total_gib": "4c3b…" },
    "gpu": [{ "vendor": "9a8f…", "device": "7c6e…" }],
    "network": { "interfaces": ["ab12…", "cd34…"], "bluetooth": ["ef56…"] },
    "os": { "kernel": "3b2a…", "id": "1d0c…", "is_docker": true }
  }
}
```

`machine_fingerprint` is removed. `machine_signals` is added. Everything else (`email`,
`plan`, `network`) is unchanged. The Portal ignores unknown fields and accepts missing
`machine_fingerprint` once deployed — the two changes are independently safe to ship.

### Changes to `client.ex`

**`onboard_user/1` (line 34–64):**
- Remove `alias Zaq.System.MachineFingerprint` → `alias Zaq.System.MachineSignals`
- Remove `fingerprint = MachineFingerprint.get()` (line 36)
- Replace `machine_fingerprint: fingerprint` with `machine_signals: MachineSignals.collect()` in the JSON map
- Add 409 error clauses to `portal_error_code/2` (currently at line 98, only covers
  `email_taken`); new codes emitted by the Portal for signal-based deduplication:

```elixir
# existing
defp portal_error_code(409, %{"error" => "email_already_registered"}), do: :email_taken
# new
defp portal_error_code(409, %{"error" => "machine_already_registered"}), do: :machine_taken
defp portal_error_code(409, %{"error" => "machine_fingerprint_taken"}), do: :machine_taken
```

Both new codes surface as `:machine_taken` — same UX contract as the existing
machine-conflict flow already shipped in the LiveView layer.

**`update_email/1` (line 67–92):** unchanged in this plan. Still uses
`Bearer #{MachineFingerprint.get()}` — tracked as Step 5 (follow-up token replacement).
`MachineFingerprint` module is NOT deleted; only its use in `onboard_user/1` is replaced.

## Implementation steps

### Step 1 — `Zaq.System.MachineSignals` (new module)

New module under `lib/zaq/system/machine_signals.ex`. Responsibilities:
- Expose `collect/0` → returns the `machine_signals` map (already structured, values hashed)
- One function per signal group (`identity/0`, `motherboard/0`, `cpu/0`, `gpu/0`,
  `network/0`, `os_info/0`, `attestation/0`) — each returns a map or nil
- Every probe wrapped in `try/rescue` (nil file → key omitted, parse error → key omitted)
- IMDS probes: plain HTTP to link-local addresses, 500ms timeout, silent skip on error.
  AWS requires IMDSv2: PUT `/latest/api/token` with `X-aws-ec2-metadata-token-ttl-seconds`
  header first, then GET with the returned token. GCP requires `Metadata-Flavor: Google`.
  Azure requires `Metadata: true`.
- Config-injectable paths (same pattern as existing `machine_id_paths`) so tests can point
  probes at fixture files without touching real `/proc`/`/sys`
- Memoized in `:persistent_term` — probes run once per boot, `collect/0` returns cached
  result on subsequent calls

Helper: `hash_signal(name, value)` — implements the wire-format hash. `normalize/1` is
pure and exported for the shared test-vector suite.

### Step 2 — Remove `Zaq.System.MachineFingerprint` dependency from onboarding

`Zaq.UserPortal.Client.onboard_user/1` currently builds:

```elixir
machine_fingerprint: MachineFingerprint.get()
```

Replace with:

```elixir
machine_signals: MachineSignals.collect()
```

`MachineFingerprint` is not deleted (it may be used elsewhere — check with
`mix xref callers Zaq.System.MachineFingerprint`), but it is removed from the onboarding
payload. The `machine_fingerprint` key is dropped from the onboarding JSON.

Also handle the Portal's 409 `machine_already_registered` code here (joins the existing
`machine_fingerprint_taken` / `email_already_registered` handling — same UX contract).

### Step 3 — Remove machine-id bind mount from `docker-compose.yml`

The `/etc/machine-id:/etc/machine-id:ro` mount is now just one optional signal among many.
Remove it from the shipped compose — it both advertises the resettable mechanism and is the
exact file the abuser targets. Existing installs that keep their own mount will still have
`machine_id` collected (it reads the file normally); the bind mount is no longer in the
default config.

### Step 4 — Deploy docs

- Note that `product_uuid` / `board_serial` / `chassis_serial` are nil on Docker bridge
  containers running as non-root (expected — Portal handles sparse payloads)
- AWS IMDSv2 hop-limit note: set `HttpPutResponseHopLimit=2` on the EC2 instance if
  running ZAQ in a Docker container on EC2 and cloud attestation is desired
- Existing-install note: removing the machine-id bind mount changes which signals are
  present — existing installs may re-onboard with a different signal set

### Step 5 — Replace fingerprint with `litellm_api_key` in `update_email/1`

`client.ex:75` uses `Bearer #{MachineFingerprint.get()}` as the auth token for
`update_email/1`. Replace with `Bearer #{litellm_api_key}` — the Portal authenticates
the account via the API key issued at onboarding.

**Signature change:** `update_email(email)` → `update_email(email, litellm_api_key)`

**Wire format:**
- Header: `Authorization: Bearer #{litellm_api_key}`
- Body: `%{email: new_email}` (unchanged)

**Lost key / DB wiped:** if `litellm_api_key` is nil or the Portal returns 401/403, the
local email change still succeeds but the caller surfaces a clear message to the user:
"Your email was updated in ZAQ but could not be synced to the Portal — your Portal
account still uses the old email."

Remove `alias Zaq.System.MachineFingerprint` from `client.ex` entirely once this step is
done — it will have no remaining callers in the file.

## Tests

- **`MachineSignals.collect/0`**: each signal group parses real fixture output from
  `/proc`/`/sys` files; missing/unreadable source → key omitted from map; raw values never
  appear in output (assert hashes only; attestation doc exempt); deterministic per identical
  input; IMDS probes time out silently without raising
- **`hash_signal/2` + `normalize/1`**: shared test-vector fixture
  (`test/fixtures/signal_hash_vectors.json` — `(name, raw_value) → expected_32hex`) copied
  verbatim into the Portal repo; both implementations must reproduce identical hashes
- **`MachineFingerprint`**: existing tests unaffected (module still exists)
- **`Client`**: onboarding payload contains `machine_signals` matching wire format; no
  `machine_fingerprint` key in payload; existing 409/machine-conflict flow unaffected;
  `update_email/2` sends `Authorization: Bearer #{litellm_api_key}`; on 401/403 or nil
  key, local change succeeds and caller receives `:portal_sync_failed`
- **Property tests** (per `docs/testing-approach.md`): `normalize/1` is idempotent;
  `hash_signal/2` never raises on arbitrary binary input; `collect/0` never raises
  regardless of which files are absent/garbage
- Target ≥95% coverage. `mix format` + `mix q` before PR.

## Rollout

1. Steps 1–5 ship together — additive payload; Portal ignores `machine_signals` until
   ready. The `machine_fingerprint` field is dropped from this release, as is the
   fingerprint-as-bearer-token in `update_email/1`.
2. Portal: store signals per onboarding, build deduplication + trust-tier credit policy
   from the signal map (vendor repo).

## Open items

- Decide with Portal team: exact signal fields they plan to deduplicate on (affects which
  fields are worth the collection effort vs. always-nil in Docker)
- RAM bucketing granularity: nearest GiB vs power-of-two bucket
- GPU: PCI class filter `0x03xxxx` covers display controllers — confirm with Portal whether
  compute-only GPUs (class `0x12xxxx`) should also be included
- Existing-install migration: users who re-onboard after losing their machine-id mount will
  present a different signal set — coordinate Portal-side handling timing
