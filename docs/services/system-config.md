# System Configuration

This document covers runtime requirements for Back Office system settings,
including AI model configuration and SMTP secret encryption.

## AI Model Configuration (LLM, Embedding, Image-to-Text)

AI model settings are configured in Back Office at `/bo/system-config` and
persisted in `system_configs`.

- LLM config is read via `Zaq.System.get_llm_config/0`
- Embedding config is read via `Zaq.System.get_embedding_config/0`
- Image-to-text config is read via `Zaq.System.get_image_to_text_config/0`

### LLM Keys

- `llm.credential_id`
- `llm.model`
- `llm.temperature`
- `llm.top_p`
- `llm.supports_logprobs`
- `llm.supports_json_mode`
- `llm.max_context_window`
- `llm.distance_threshold`

### Embedding Keys

- `embedding.credential_id`
- `embedding.model`
- `embedding.dimension`
- `embedding.chunk_min_tokens`
- `embedding.chunk_max_tokens`

### Image-to-Text Keys

- `image_to_text.credential_id`
- `image_to_text.model`

These keys are no longer configured through `LLM_*`, `EMBEDDING_*`, or
`IMAGE_TO_TEXT_*` environment variables.

Connection fields (`provider`, `endpoint`, `api_key`) are sourced from
`ai_provider_credentials` referenced by each `*.credential_id`.

## MCP Endpoint Runtime Configuration

MCP endpoint changes from Back Office (`/bo/system-config`) are applied through
an event-first boundary:

- BO emits `NodeRouter.dispatch/1` action `:mcp_endpoint_updated` (destination `:agent`)
- `Zaq.Agent.Api` receives the action and delegates to `Zaq.Agent.RuntimeSync`
- `RuntimeSync` applies the required runtime updates for impacted configured agents

This prevents BO LiveViews from calling runtime modules directly and keeps
single-node/multi-node behavior consistent.

### Signal Adapter Pattern

The `:mcp_endpoint_updated` action acts as an adapter signal from configuration
changes to runtime operations:

- create/update/enable endpoint -> sync MCP assignment runtime state
- disable/delete endpoint -> unsync runtime state for impacted agents

### Hot Runtime Patch Strategy

For MCP assignment-only changes, runtime sync prefers hot patching existing
running agent servers (no full restart required).

For structural configured-agent runtime changes (model/credential/job/strategy/
tool/options/flags), normal fingerprint-based restart behavior still applies.

### Atom and Capacity Guards

MCP runtime endpoint ids are deterministic (`:"mcp_<id>"`) and managed by
`Zaq.Agent.MCP.Runtime` with safety guardrails:

- atom memory usage threshold: block new endpoint atom creation at `>= 85%`
- endpoint hard cap: maximum `2000` MCP endpoints

These checks exist to prevent atom-table exhaustion and uncontrolled runtime
growth in long-lived nodes.

## Secret Persistence Standard (Strict, Global)

All sensitive values (API keys, tokens, passwords) must follow one strict write path:

1. Validate form changeset
2. Encrypt sensitive values with `Zaq.Types.EncryptedString.encrypt/1`
3. Persist encrypted payload only
4. If encryption fails, return `{:error, %Ecto.Changeset{}}` with a field-level error

There is no fallback to plaintext persistence.

### Current sensitive fields

- `ai_provider_credentials.api_key`
- `email.password`
- `channel_configs.token`

### Error contract

- Missing key: field error contains `missing SYSTEM_CONFIG_ENCRYPTION_KEY`
- Invalid key: field error contains `invalid SYSTEM_CONFIG_ENCRYPTION_KEY`
- Other encryption errors: field error contains `could not be encrypted`

All BO forms must surface these errors to the user in the related input form.

## SMTP Password Encryption

ZAQ encrypts SMTP passwords before persisting them in `system_configs`.

- Encrypted at rest: `email.password`
- Module: `Zaq.System.SecretConfig`
- Cipher: AES-256-GCM
- Strict mode: saving a non-empty SMTP password fails if encryption config is missing or invalid

## Required Configuration

Configure this in runtime config (production) or local secret config (development).
For local Docker runs started with `./zaq-local.sh`, ZAQ writes `SYSTEM_CONFIG_ENCRYPTION_KEY` to `.env` automatically.


```elixir
config :zaq, Zaq.System.SecretConfig,
  encryption_key: System.get_env("SYSTEM_CONFIG_ENCRYPTION_KEY"),
  key_id: System.get_env("SYSTEM_CONFIG_ENCRYPTION_KEY_ID", "v1")
```

## Key Format

`SYSTEM_CONFIG_ENCRYPTION_KEY` must represent exactly 32 bytes. Accepted formats:

1. Raw 32-byte string
2. Base64 value decoding to 32 bytes (recommended)
3. 64-character hex string (32 bytes)

Generate a recommended key:

```bash
openssl rand -base64 32
```

## Key ID

`SYSTEM_CONFIG_ENCRYPTION_KEY_ID` defaults to `v1`.

- Included in encrypted payload metadata
- Intended for key rotation workflows
- Changing key id without providing matching key makes old ciphertext undecryptable

## Failure Modes

- Missing key on save: BO save fails for any sensitive field and shows a form-level encryption error
- Invalid key format: BO save fails for any sensitive field and shows a form-level encryption error
- Invalid ciphertext/decryption failure: SMTP test/delivery fails until password is re-saved with valid key config

## New Secret Field Checklist

When adding a new key/token/password field:

1. Use strict encryption (`EncryptedString.encrypt/1`) in the write path.
2. Return `{:error, %Ecto.Changeset{}}` on encryption failures (no `raise`, no plaintext fallback).
3. Ensure the LiveView/form displays field errors.
4. Add unit tests for success + missing key + invalid key.
5. Add LiveView regression test proving clear UI error rendering.

## Operational Notes

- Keep encryption key in secret storage (Kubernetes Secret, Vault, cloud secret manager, etc.)
- Do not commit raw key values in repository files
- For local development, prefer env vars loaded via untracked local secret files
