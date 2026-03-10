# License Service

## Overview

The License service handles loading, verifying, and hot-reloading `.zaq-license` packages
at runtime. It is responsible for feature gating and dynamically loading encrypted BEAM
modules shipped inside license files.

This service runs independently of the other services and is not tied to a role —
`FeatureStore` and `LicenseWatcherFS` are started as part of the main application.

---

## Architecture

```
priv/licenses/*.zaq-license       ← watched directory
  └── LicenseWatcherFS            ← GenServer, OS-level file events via FileSystem
        └── Loader.load/1
              ├── extract_package/1       ← untar .zaq-license (gzipped tar)
              ├── Verifier.verify/2       ← Ed25519 signature check
              ├── check_expiry/1          ← DateTime comparison
              ├── BeamDecryptor           ← AES-256-GCM decrypt BEAM modules
              ├── :code.load_binary       ← load decrypted BEAM into VM
              ├── FeatureStore.store/2    ← persist license data + modules to ETS
              └── LicensePostLoader.notify/2  ← run migrations, post-load hooks
```

---

## What's Done

### License Package Format (`.zaq-license`)
- Gzipped tar archive containing:
  - `license.dat` — base64-encoded JSON payload + Ed25519 signature, separated by `.`
  - `modules/*.beam.enc` — AES-256-GCM encrypted BEAM files
  - `migrations/*.exs` — optional Ecto migration files

### Loader (`Zaq.License.Loader`)
- `load/1` — full pipeline: extract → verify → decode → check expiry → decrypt modules → store
- Extracts migration files and passes them to `LicensePostLoader`
- On success: stores license data and loaded module atoms in `FeatureStore`
- On failure: logs error and returns `{:error, reason}`

### Verifier (`Zaq.License.Verifier`)
- Ed25519 signature verification using `:crypto.verify/5`
- Public key loaded from `priv/keys/public.pem` at runtime
- `verify/2` — returns `:ok` or `{:error, :invalid_signature}`
- `parse_public_pem/1` — strips PEM headers, base64-decodes to raw 32-byte key

### BEAM Decryptor (`Zaq.License.BeamDecryptor`)
- `derive_key/1` — SHA-256 hash of the raw license payload → 256-bit AES key
- `decrypt/2` — AES-256-GCM decryption
- Binary format: `iv (12 bytes) <> tag (16 bytes) <> encrypted_data`
- AAD: `"zaq-beam-v1"`
- Returns `{:ok, beam_binary}` or `{:error, :decryption_failed}`

### Feature Store (`Zaq.License.FeatureStore`)
- GenServer backed by ETS table (`:zaq_license_features`)
- ETS config: `:set`, `:named_table`, `:protected`, `read_concurrency: true`
- `store/2` — writes license data and loaded module list to ETS
- `license_data/0` — returns raw license JSON map or `nil`
- `loaded_modules/0` — returns list of loaded module atoms
- `feature_loaded?/1` — checks if a feature name exists in `license_data["features"]`
- `module_loaded?/1` — checks if a module atom is in the loaded list
- `clear/0` — wipes all ETS entries (useful for testing)

### License Watcher (`Zaq.License.LicenseWatcherFS`)
- GenServer watching `priv/licenses/` for `.zaq-license` files
- Uses `FileSystem` library for OS-level file events (inotify/FSEvents)
- 500ms debounce on rapid file events (e.g. during writes)
- Tracks file mtimes — only reloads on new or modified files
- Detects deleted license files and unloads them from state
- `status/0` — returns watch dir, loaded count, license keys, current status
- `force_scan/0` — triggers immediate directory scan
- `loaded_licenses/0` — returns list of currently loaded license keys
- `unload_license/1` — removes a license by key

---

## Files

```
lib/zaq/license/
├── beam_decryptor.ex         # AES-256-GCM decryption of encrypted BEAM files
├── feature_store.ex          # GenServer + ETS for runtime license/feature queries
├── license_post_loader.ex    # Post-load hooks: migrations, notifications
├── license_watcher_fs.ex     # GenServer watching priv/licenses/ for .zaq-license files
├── loader.ex                 # Full load pipeline: extract, verify, decrypt, store
└── verifier.ex               # Ed25519 signature verification

priv/
├── keys/
│   └── public.pem            # Ed25519 public key for signature verification
└── licenses/                 # Drop .zaq-license files here (watched at runtime)
```

---

## Configuration

```elixir
# No runtime config keys required.
# Watch directory is hardcoded to "priv/licenses/".
# Public key path is hardcoded to "priv/keys/public.pem".
```

To change watch directory, pass as option when starting `LicenseWatcherFS`:

```elixir
{Zaq.License.LicenseWatcherFS, watch_dir: "custom/path"}
```

---

## Key Design Decisions

- **File-system events, not polling** — uses `FileSystem` (inotify/FSEvents) for efficiency
- **Key derived from payload** — AES key is `SHA-256(payload)`, so the signature also protects the encryption key
- **BEAM loaded into VM at runtime** — licensed features are Elixir modules decrypted and loaded dynamically via `:code.load_binary`
- **ETS for fast reads** — `feature_loaded?/1` and `module_loaded?/1` are hot-path calls, ETS avoids GenServer bottleneck
- **Graceful missing key** — `Verifier.public_key/0` returns `{:error, :no_public_key}` if `priv/keys/public.pem` is absent

---

## What's Left

### Must Do
- [ ] Implement `LicensePostLoader.notify/2` — run bundled migrations and post-load hooks
- [ ] Document the `.zaq-license` build/signing process (for the license manager tool)

### Should Do
- [ ] Expose license status in BO (`license_live.ex` is stubbed)
- [ ] Validate `license_data["features"]` structure on load
- [ ] Handle license expiry gracefully at runtime (warn before expiry, disable after)

### Nice to Have
- [ ] Multiple license files support (already partially handled by watcher)
- [ ] License audit log (who loaded what and when)
- [ ] Grace period after expiry before hard cutoff