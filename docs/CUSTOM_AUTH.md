# Custom Auth

LiteLLM Proxy uses a custom auth handler (`infra/custom_auth.py`) to validate client
API keys. No database required — keys are injected as a Container App secret.

## How It Works

1. `custom_auth.py` is rendered as a Container Apps secret (`custom-auth-py`)
2. The main container entrypoint copies it to `/app/custom_auth.py` alongside `config.yaml`
3. LiteLLM loads it via `general_settings.custom_auth: custom_auth.user_api_key_auth`
4. On each request, the handler validates the Bearer token against the key set
5. Keys are loaded from `API_KEYS` env var on first request and cached in memory

`custom_auth` runs **before** LiteLLM's built-in master key check and replaces it
entirely. The handler therefore also accepts `LITELLM_MASTER_KEY` so admin
operations keep working.

## Key Management

Keys are set via `TF_VAR_api_keys` in `infra/.env` — comma-separated list:

```sh
TF_VAR_api_keys=sk-clientA,sk-clientB,sk-clientC
```

Generate a key:
```sh
openssl rand -base64 32 | tr -d "=+/" | cut -c1-40 | sed 's/^/sk-/'
```

### Add or Revoke a Key

1. Edit `infra/.env` — add/remove from `TF_VAR_api_keys`
2. Apply:
   ```sh
   cd infra && terraform apply -auto-approve
   ```
3. New Container App revision deploys with updated secrets. Old revision deactivated.

## Master Key vs Client Keys

| Key | Variable | Purpose |
|---|---|---|
| Master key | `TF_VAR_litellm_master_key` | Admin ops — use for yourself, not clients |
| Client keys | `TF_VAR_api_keys` | Distribute to clients; comma-separated |

Master key does **not** need to appear in `api_keys` — the handler loads both independently.

## Client Usage

```bash
curl https://<fqdn>/v1/chat/completions \
  -H "Authorization: Bearer sk-clientA" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4.1", "messages": [{"role": "user", "content": "Hello"}]}'
```

## Limitations

- Key changes require `terraform apply` — no hot reload
- All keys have access to all models (no per-key model restrictions yet)
- No spend tracking per key
- No Admin UI
- Keys cached in memory — process restart (new revision) picks up changes
- All responses-only models are still controlled by the same key set as chat models
