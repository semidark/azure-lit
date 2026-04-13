# Key Management

## Overview

Authentication is handled by `custom_auth.py`, which validates Bearer tokens against two sources:

- **Client API keys** — comma-separated list in `TF_VAR_api_keys` → `API_KEYS` env var
- **Master key** — `TF_VAR_litellm_master_key` → `LITELLM_MASTER_KEY` env var

The master key is for admin/operator use. Client keys are distributed to API consumers.
Neither needs to appear in the other's variable — the handler loads both independently.

## Key Storage

- Both are stored as Azure Container Apps secrets (never in git).
- Source of truth: `infra/.env` (gitignored).

## Client Usage

```bash
curl -sS \
  -H "Authorization: Bearer <api_key>" \
  https://<your-container-app-host>/v1/models
```

OpenAI SDK:
```python
from openai import OpenAI
client = OpenAI(api_key="<api_key>", base_url="https://<your-container-app-host>")
resp = client.chat.completions.create(
    model="gpt-4.1",
    messages=[{"role":"user","content":"hello"}],
)
print(resp.choices[0].message.content)
```

## Adding or Revoking Client Keys

1. Edit `infra/.env` — update `TF_VAR_api_keys` (comma-separated):
   ```sh
   TF_VAR_api_keys=sk-clientA,sk-clientB
   ```
2. Apply:
   ```sh
   cd infra && terraform apply -auto-approve
   ```
3. New Container App revision deploys. Old revision deactivated.

Generate a new key:
```sh
openssl rand -base64 32 | tr -d "=+/" | cut -c1-40 | sed 's/^/sk-/'
```

## Rotating the Master Key

1. Generate a new key:
   ```sh
   openssl rand -base64 48 | tr -d "=+/" | cut -c1-64 | sed 's/^/sk-/'
   ```
2. Update `TF_VAR_litellm_master_key` in `infra/.env`.
3. Apply:
   ```sh
   cd infra && terraform apply -auto-approve
   ```

## Behavior Summary

- `custom_auth` replaces LiteLLM's built-in master key check entirely.
- Keys are loaded from env vars on first request and cached for the process lifetime.
- Key changes take effect only after redeploy (new Container App revision).
- No DB, no virtual keys, no Admin UI or key-management routes.

## Security Notes

- Use HTTPS only.
- Restrict access to `infra/.env` and Azure resources.
- Do not log prompts/responses — metadata-only logging per project policy.
- All secrets encrypted at rest in Container Apps.
