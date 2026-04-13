# Master Key Management

## Overview

For the PoC, LiteLLM Proxy is secured using a single MASTER_KEY. When a MASTER_KEY is configured (even without a database), client requests to the proxy MUST include this key in the Authorization header. Without a MASTER_KEY configured, the proxy is unauthenticated and will accept requests without credentials (suitable only for local development).

## Key Storage and Configuration

- Store the MASTER_KEY as an Azure Container Apps secret (never in git).
- Provide it to the container via environment variable `LITELLM_MASTER_KEY` or set `general_settings.master_key` in `config.yaml`.
- The key should follow LiteLLM conventions and start with `sk-`.

### Source of Truth (Local Dev / Terraform)
- `infra/.env` contains `TF_VAR_litellm_master_key` used by Terraform to inject the Container Apps secret.
- Ensure `.env` is in `.gitignore` and never committed.

## Client Usage

Include the MASTER_KEY in the Authorization header for all requests:

```bash
curl -sS \
  -H "Authorization: Bearer <MASTER_KEY>" \
  https://<your-container-app-host>/v1/models
```

OpenAI SDK example:
```python
from openai import OpenAI
client = OpenAI(api_key="<MASTER_KEY>", base_url="https://<your-container-app-host>")
resp = client.chat.completions.create(
    model="gpt-4.1",
    messages=[{"role":"user","content":"hello"}],
)
print(resp.choices[0].message.content)
```

## Behavior Summary

- MASTER_KEY set: authentication is enforced; requests without the correct key are rejected.
- No MASTER_KEY set: no authentication; only acceptable for local/dev.
- No database: single shared credential (MASTER_KEY); no per-user budgets/permissions; no Admin UI/virtual keys.

## Rotation Procedure

1. Generate a new secure key (example):
   ```bash
   openssl rand -base64 48 | tr -d "=+/" | cut -c1-64 | sed 's/^/sk-/'
   ```
2. Update `infra/.env` with the new value for `TF_VAR_litellm_master_key`.
3. Apply infrastructure changes:
   ```bash
   cd infra
   # With direnv: direnv allow
   # Without direnv:
   export $(grep -v '^#' .env | grep -v '^$' | xargs)
   terraform apply -auto-approve
   ```
4. Verify clients are using the new key (update any stored credentials).

## Security Notes

- Use HTTPS only.
- Limit access to the `.env` file and Azure resources.
- Prefer Container Apps secrets for PoC; adopt Key Vault for provider secrets in MVP.
- Do not log prompts/responses; metadata-only logging per project policy.

## Moving Beyond PoC (Production Considerations)

For multi-client scenarios and per-user budgets/permissions:
- Enable a database and LiteLLM Virtual Keys to issue individual API keys.
- Alternatively, integrate a custom key store (e.g., Azure Table Storage) and enforce keys via custom auth or service-layer middleware.

References:
- LiteLLM Proxy Master Key: general_settings.master_key / `LITELLM_MASTER_KEY`
- LiteLLM Virtual Keys (multi-tenant): https://docs.litellm.ai/docs/proxy/virtual_keys
