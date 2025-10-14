# LiteLLM Proxy Custom Auth 

Goal: Strict, pay-as-you-go authentication without adding managed services (no Front Door, no DB). Enforce a single master key or a small key list at the proxy edge.

## Why Custom Auth

LiteLLM Proxy is permissive by default. The `master_key` is used for proxy admin/virtual keys and is not strictly enforced for client requests unless you add validation. `custom_auth` lets you inject a lightweight check that runs before request execution.

## Requirements

- LiteLLM Proxy container (we use `ghcr.io/berriai/litellm:main-stable` or a stable tag).
- A Python module file inside the container filesystem (e.g., `/app/custom_auth.py`).
- Environment variable containing your master key (`LITELLM_MASTER_KEY`).
- No external databases or paid gateways.

## Design

- Implement `user_api_key_auth(request, api_key)` function returning `UserAPIKeyAuth` on success or raising on failure.
- Configure in `config.yaml` under `general_settings.custom_auth`.
- Use `custom_auth_settings.mode: "on"` for strict enforcement (only custom auth). If your image build has a parsing issue with `mode: on`, fall back temporarily to `mode: "auto"` and combine with network/IP restrictions until upgrading.
- Set `litellm_settings.drop_params: true` to prevent clients from overriding provider credentials.

## Example: Single Master Key (Strict)

File: `/app/custom_auth.py`
```python
from fastapi import Request
from litellm.proxy._types import UserAPIKeyAuth
import os

MASTER_KEY_ENV = "LITELLM_MASTER_KEY"

async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    required_key = os.environ.get(MASTER_KEY_ENV)
    if not required_key:
        raise Exception("Proxy misconfiguration: master key not set")
    if api_key == required_key:
        return UserAPIKeyAuth(api_key=api_key)
    raise Exception("Invalid API key")
```

Config: `config.yaml`
```yaml
model_list:
  - model_name: gpt-4.1
    litellm_params:
      model: azure/gpt-4.1
      api_base: os.environ/AZURE_OPENAI_API_BASE
      api_key: os.environ/AZURE_OPENAI_API_KEY
      api_version: os.environ/AZURE_OPENAI_API_VERSION

litellm_settings:
  drop_params: true

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  custom_auth: custom_auth.user_api_key_auth
  custom_auth_settings:
    mode: "on"  # strict; only custom auth
  forward_client_headers_to_llm_api: false
  store_model_in_db: false
  disable_spend_logs: true
  disable_spend_updates: true
  disable_adding_master_key_hash_to_db: true
  disable_reset_budget: true
  allow_requests_on_db_unavailable: true
  timeout: 60
```

Notes:
- Ensure the module path matches (`custom_auth.user_api_key_auth` resolves from PYTHONPATH). Mount or write `custom_auth.py` to `/app` and set `PYTHONPATH=/app` in your container env.
- Keys often use `sk-` prefix; it’s safe to enforce format if you like. The above only checks equality.

## Example: Small Allowlist of Keys

```python
ALLOWED_KEYS = {"sk-abc", "sk-def"}

async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    if api_key in ALLOWED_KEYS:
        return UserAPIKeyAuth(api_key=api_key)
    raise Exception("Invalid API key")
```

## Deploying on Azure Container Apps (ACA)

- Write `config.yaml` and `custom_auth.py` into a shared EmptyDir volume via an init container using ACA secrets.
- Set env: `LITELLM_MASTER_KEY` from a secret. Optional: `PYTHONPATH=/app`.
- Start the proxy with: `litellm --config /app/config.yaml --port 4000 --host 0.0.0.0`.

Terraform pattern (concept):
- secrets: `config-yaml` and `custom-auth-py` containing file contents.
- init_container: writes both to `/mnt/config`; main container mounts `/app` to the same volume.
- env: `PYTHONPATH=/app`, `LITELLM_MASTER_KEY` from secret.

## Verification

- Valid key: `curl -H "Authorization: Bearer <MASTER_KEY>" https://<app>/v1/models` → 200.
- Invalid key: `curl -H "Authorization: Bearer sk-invalid" https://<app>/v1/models` → 401.
- No header: `curl https://<app>/v1/models` → 401.

If you get `{"error":{"message":"Authentication Error, Invalid mode: True"...}}`:
- Your image may have a config parsing bug for `mode`. Try quoting, uppercase, or upgrade image tag. As a temporary workaround set `mode: "auto"` and add IP allowlist on ACA ingress until you upgrade.

## Operational Considerations

- Rotation: update `LITELLM_MASTER_KEY` secret (e.g., via Terraform env TF_VAR_litellm_master_key), apply, and restart the container revision.
- Logging: keep `forward_client_headers_to_llm_api: false` and avoid content logging per policy.
- Security: never commit `.env` or secrets; store provider keys in Container Apps secrets or Key Vault (MVP).

## Troubleshooting

- 200 with invalid keys: custom_auth not wired or `mode` not enforced; check `custom_auth` path, `PYTHONPATH`, and image tag.
- 500 errors on import: container missing `custom_auth.py` in the expected path; verify volume mount.
- YAML pitfalls: unquoted `on`/`off` can be parsed as booleans; always quote: `"on"`, `"auto"`.

## Documentation Links

- LiteLLM Proxy Custom Auth: https://docs.litellm.ai/docs/proxy/custom_auth
- LiteLLM Proxy Virtual Keys (for future multi-tenant key management): https://docs.litellm.ai/docs/proxy/virtual_keys
- LiteLLM Proxy Overview & Getting Started (root docs index): https://docs.litellm.ai/

## Next Steps

- Start with single master key enforcement. If multi-tenant is needed later, consider LiteLLM virtual keys + DB or a lightweight key store (Table Storage) with hash validation.
