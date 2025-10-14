# Proof-of-Concept (PoC) — LiteLLM Proxy on Azure Container Apps

Goal: Validate OpenAI-compatible API (including streaming) via LiteLLM Proxy, fronting Azure OpenAI deployments, with minimal infrastructure and a single shared credential.

## Scope
- OpenAI-compatible endpoints: `/v1/chat/completions` (streaming supported) and `/v1/models`
- Static model list via `config.yaml` (no discovery)
- External HTTPS ingress on Azure Container Apps
- Authentication: MASTER_KEY-only (no database, no virtual keys)
- Minimal secrets footprint (Container Apps secrets; no Key Vault in PoC unless required)
- Region default: Sweden Central

## Architecture
- Azure Container App runs the official LiteLLM Proxy image (`ghcr.io/berriai/litellm:main-latest`)
- `config.yaml` defines `model_list` entries that point to Azure OpenAI deployments
- Environment variables provide provider credentials (e.g., `AZURE_API_BASE`, `AZURE_API_KEY`, `AZURE_API_VERSION`)
- Logs to Log Analytics via Container Apps

## Configuration — Models (config.yaml)
Example entry:
```yaml
model_list:
  - model_name: gpt-4o-mini
    litellm_params:
      model: azure/<your_azure_deployment_name>
      api_base: os.environ/AZURE_API_BASE
      api_key: os.environ/AZURE_API_KEY
      api_version: os.environ/AZURE_API_VERSION
```
Define multiple models as needed; clients select by `model_name`.

## Authentication — MASTER_KEY Only
- Set a single MASTER_KEY for the proxy via either:
  - Environment variable: `LITELLM_MASTER_KEY`, or
  - `general_settings.master_key` in `config.yaml`
- When a MASTER_KEY is set, LiteLLM enforces client authentication: clients MUST include the master key in the Authorization header for all requests.

Client header format:
```
Authorization: Bearer <MASTER_KEY>
```
Notes:
- The MASTER_KEY must start with `sk-` to be considered valid
- Without a database, all clients share the same credential (the MASTER_KEY)
- Without setting any MASTER_KEY, the proxy is unauthenticated (suitable only for local development)

What you cannot do without a database:
- Create per-client virtual keys with budgets/permissions
- Track spending per key/user/team
- Use the Admin UI for key management

## Streaming Behavior
- Clients set `stream=true`; LiteLLM emits OpenAI-style `chat.completion.chunk` events until completion

## Client Example
Python (OpenAI SDK-compatible):
```python
from openai import OpenAI
client = OpenAI(api_key="<MASTER_KEY>", base_url="https://<your-container-app>" )
resp = client.chat.completions.create(
    model="gpt-4o-mini",
    messages=[{"role":"user","content":"hello"}]
)
print(resp.choices[0].message.content)
```
Curl:
```bash
curl -sS \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "hello"}],
    "stream": false
  }' \
  https://<your-container-app>/v1/chat/completions
```

## Terraform (Overview)
- Resource Group, Log Analytics Workspace, Container Apps Environment (external ingress)
- Container App:
  - Image: LiteLLM Proxy
  - Target port: 4000
  - Env: `AZURE_API_BASE`, `AZURE_API_KEY` (secret), `AZURE_API_VERSION`, `LITELLM_MASTER_KEY` (secret)
  - `config.yaml` injection via secret + init container to mount file into `/app/config.yaml`

## Security
- Store provider keys and `LITELLM_MASTER_KEY` as Container Apps secrets; never commit to git
- Use HTTPS only
- Restrict ingress (IP allowlist) if needed for testing

## Limitations (Intentional in PoC)
- No dynamic model discovery; redeploy to change `model_list`
- No per-user keys, budgets, or Admin UI
- Chat completions only; other endpoints out of scope

## Next Steps Toward MVP
- Introduce a key store (e.g., Table Storage) for per-client virtual keys
- Add model discovery and `/v1/models` backed by a catalog
- Streamlined routing across Azure OpenAI and Azure AI Foundry serverless endpoints
- Telemetry to Azure Monitor (latency, errors, token counts)
