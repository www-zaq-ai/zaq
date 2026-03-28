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

- `llm.provider`
- `llm.endpoint`
- `llm.api_key`
- `llm.model`
- `llm.temperature`
- `llm.top_p`
- `llm.supports_logprobs`
- `llm.supports_json_mode`
- `llm.max_context_window`
- `llm.distance_threshold`

### Embedding Keys

- `embedding.provider`
- `embedding.endpoint`
- `embedding.api_key`
- `embedding.model`
- `embedding.dimension`
- `embedding.chunk_min_tokens`
- `embedding.chunk_max_tokens`

### Image-to-Text Keys

- `image_to_text.provider`
- `image_to_text.endpoint`
- `image_to_text.api_key`
- `image_to_text.model`

These keys are no longer configured through `LLM_*`, `EMBEDDING_*`, or
`IMAGE_TO_TEXT_*` environment variables.

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

- Missing key on save: BO save fails for SMTP settings that include a non-empty password
- Invalid key format: BO save fails with encryption-key error
- Invalid ciphertext/decryption failure: SMTP test/delivery fails until password is re-saved with valid key config

## Operational Notes

- Keep encryption key in secret storage (Kubernetes Secret, Vault, cloud secret manager, etc.)
- Do not commit raw key values in repository files
- For local development, prefer env vars loaded via untracked local secret files
