# Add-ons Service

## Overview

The Add-ons service handles loading, verifying, and hot-reloading signed
`.zaq-license` add-on packages at runtime. It is responsible for feature
gating and dynamically loading encrypted BEAM modules shipped inside add-on
packages.

This is not the product/legal licensing surface. Legal licensing lives in
`LICENSE`, `NOTICE`, `COMMERCIAL-LICENSE.md`, and `CLA.md`.

This service runs independently of the other services and is not tied to a role —
`FeatureStore` is started as part of the main application.

---

## Architecture

```
priv/licenses/*.zaq-license       ← watched directory
        └── PackageLoader.load/1
              ├── extract_package/1       ← untar .zaq-license (gzipped tar)
              ├── PackageVerifier.verify/2       ← Ed25519 signature check
              ├── check_expiry/1          ← DateTime comparison
              ├── BeamDecryptor           ← AES-256-GCM decrypt BEAM modules
              ├── :code.load_binary       ← load decrypted BEAM into VM
              ├── FeatureStore.store/2    ← persist add-on data + modules to ETS
              └── PostLoader.notify/2  ← run migrations, post-load hooks
```

---

## What's Done

### Add-on Package Format (`.zaq-license`)

- Gzipped tar archive containing:
  - `license.dat` — base64-encoded JSON payload + Ed25519 signature, separated by `.`
  - `modules/*.beam.enc` — AES-256-GCM encrypted BEAM files
  - `migrations/*.exs` — optional Ecto migration files

### PackageLoader (`Zaq.Addons.PackageLoader`)

- `load/1` — full pipeline: extract → verify → decode → check expiry → decrypt modules → store
- Extracts migration files and passes them to `PostLoader`
- On success: stores add-on data and loaded module atoms in `FeatureStore`
- On failure: logs error and returns `{:error, reason}`

### PackageVerifier (`Zaq.Addons.PackageVerifier`)

- Ed25519 signature verification using `:crypto.verify/5`
- Public key loaded from `priv/keys/public.pem` at runtime
- `verify/2` — returns `:ok` or `{:error, :invalid_signature}`
- `parse_public_pem/1` — strips PEM headers, base64-decodes to raw 32-byte key

### BEAM Decryptor (`Zaq.Addons.BeamDecryptor`)

- `derive_key/1` — SHA-256 hash of the raw package payload → 256-bit AES key
- `decrypt/2` — AES-256-GCM decryption
- Binary format: `iv (12 bytes) <> tag (16 bytes) <> encrypted_data`
- AAD: `"zaq-beam-v1"`
- Returns `{:ok, beam_binary}` or `{:error, :decryption_failed}`

### Feature Store (`Zaq.Addons.FeatureStore`)

- GenServer backed by ETS table (`:zaq_addon_features`)
- ETS config: `:set`, `:named_table`, `:protected`, `read_concurrency: true`
- `store/2` — writes add-on data and loaded module list to ETS
- `addon_data/0` — returns raw add-on JSON map or `nil`
- `loaded_modules/0` — returns list of loaded module atoms
- `feature_loaded?/1` — checks if a feature name exists in `addon_data["features"]`
- `module_loaded?/1` — checks if a module atom is in the loaded list
- `clear/0` — wipes all ETS entries (useful for testing)

---

## Files

```
lib/zaq/addons/
├── beam_decryptor.ex         # AES-256-GCM decryption of encrypted BEAM files
├── feature_store.ex          # GenServer + ETS for runtime add-on/feature queries
├── oban_feature.ex           # Behaviour for add-on modules that declare Oban resources
├── oban_provisioner.ex       # Runtime Oban queue and cron provisioning
├── package_loader.ex         # Full load pipeline: extract, verify, decrypt, store
├── package_verifier.ex       # Ed25519 signature verification
└── post_loader.ex            # Post-load hooks: migrations, notifications

priv/
├── keys/
│   └── public.pem            # Ed25519 public key for signature verification
└── licenses/                 # Drop .zaq-license add-on packages here
```

---

## Configuration

```elixir
# No runtime config keys required.
# Add-on package directory is hardcoded to "priv/licenses/".
# Public key path is hardcoded to "priv/keys/public.pem".
```

---

## Key Design Decisions

- **File-system events, not polling** — uses `FileSystem` (inotify/FSEvents) for efficiency
- **Key derived from payload** — AES key is `SHA-256(payload)`, so the signature also protects the encryption key
- **BEAM loaded into VM at runtime** — enabled features are Elixir modules decrypted and loaded dynamically via `:code.load_binary`
- **ETS for fast reads** — `feature_loaded?/1` and `module_loaded?/1` are hot-path calls, ETS avoids GenServer bottleneck
- **Graceful missing key** — `PackageVerifier.public_key/0` returns `{:error, :no_public_key}` if `priv/keys/public.pem` is absent

---

## What's Left

### Must Do

- [ ] Implement `PostLoader.notify/2` — run bundled migrations and post-load hooks
- [ ] Document the `.zaq-license` build/signing process (for the add-on package builder)

### Should Do

- [ ] Expose add-on status in BO (`addons_live.ex` is stubbed)
- [ ] Validate `addon_data["features"]` structure on load
- [ ] Handle add-on package expiry gracefully at runtime (warn before expiry, disable after)

### Nice to Have

- [ ] Multiple add-on packages support
- [ ] Add-on audit log (who loaded what and when)
- [ ] Grace period after expiry before hard cutoff
