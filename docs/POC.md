# Proof-of-Concept (PoC) — LiteLLM Proxy on Azure Container Apps

Goal: Validate OpenAI-compatible API (including streaming) via LiteLLM Proxy, fronting Azure AI Foundry model deployments, with minimal infrastructure and a single shared credential.

## Scope
- OpenAI-compatible endpoints: `/v1/chat/completions` (streaming supported) and `/v1/models`
- Static model list via `config.yaml` (no discovery)
- External HTTPS ingress on Azure Container Apps
- Authentication: MASTER_KEY-only (no database, no virtual keys)
- Minimal secrets footprint (Container Apps secrets; no Key Vault in PoC)
- Region default: Germany West Central

## Architecture
- Azure Container App runs the official LiteLLM Proxy image (`ghcr.io/berriai/litellm:main-stable`)
- Single Azure AIServices Cognitive Account (`kind = "AIServices"`) hosts both model deployments
- `gpt-4.1` deployed directly on the account; `gpt-oss-120b` deployed into a Foundry project (`azurerm_cognitive_account_project`)
- `config.yaml` defines `model_list` entries pointing to the unified AIServices endpoint
- Environment variables provide provider credentials (`AZURE_AI_API_BASE`, `AZURE_AI_API_KEY`, `AZURE_AI_API_VERSION`)
- Logs to Log Analytics via Container Apps

## Configuration — Models (config.yaml)
Both models share the same AIServices endpoint and key:
```yaml
model_list:
  - model_name: gpt-4.1
    litellm_params:
      model: azure/gpt-4.1
      api_base: os.environ/AZURE_AI_API_BASE
      api_key: os.environ/AZURE_AI_API_KEY
      api_version: os.environ/AZURE_AI_API_VERSION
  - model_name: gpt-oss-120b
    litellm_params:
      model: azure/gpt-oss-120b
      api_base: os.environ/AZURE_AI_API_BASE
      api_key: os.environ/AZURE_AI_API_KEY
      api_version: os.environ/AZURE_AI_API_VERSION
```
Clients select by `model_name`. Add further models as needed by adding deployments in `openai.tf` and entries here.

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
- Azure AIServices Cognitive Account (`kind = "AIServices"`, `project_management_enabled = true`)
- Foundry Project (`azurerm_cognitive_account_project`) + model deployments (`azurerm_cognitive_deployment`)
- Container App:
  - Image: LiteLLM Proxy (`ghcr.io/berriai/litellm:main-stable`)
  - Target port: 4000
  - Env: `AZURE_AI_API_BASE`, `AZURE_AI_API_KEY` (secret), `AZURE_AI_API_VERSION`, `AZURE_FOUNDRY_PROJECT`, `LITELLM_MASTER_KEY` (secret)
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
