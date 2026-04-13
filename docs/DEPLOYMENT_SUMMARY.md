### Local Environment Setup

Variables are stored in `infra/.env` (gitignored). Use **direnv** to auto-export them on directory entry — install it, add the shell hook, then run `direnv allow`:

```sh
# 1. Install (example for zsh)
brew install direnv   # or apt install / pacman -S direnv

# 2. Add hook to ~/.zshrc (or ~/.bashrc), then restart shell
eval "$(direnv hook zsh)"

# 3. Create env file and allow
cp infra/example.env infra/.env  # fill in values
direnv allow
```

**Without direnv**, export manually before each session:

```sh
export $(grep -v '^#' infra/.env | grep -v '^$' | xargs)
```

---

### Deployment Summary

This Terraform plan deploys an OpenAI-compatible LiteLLM Proxy gateway on Azure Container Apps, fronting Azure AI Foundry model deployments. The deployment creates the following resources:

1. Azure Container App running the LiteLLM Proxy with external HTTPS ingress.
2. Azure AIServices Cognitive Account (`kind = "AIServices"`) — unified Foundry resource serving all models.
3. Azure Foundry Project (`azurerm_cognitive_account_project`) — always created; required by models with `project = true`.
4. Model deployments driven by `var.models` map. Currently: `gpt-4.1`, `gpt-oss-120b`, `Kimi-K2.5`, `grok-4-20-reasoning` — all account-scoped on the primary account.
5. Log Analytics Workspace for observability.

#### Model Routing

All current models share the same AIServices account endpoint and API key (`azure-ai-key-gwc` Container Apps secret):

| Model | Format | SKU | Scoped to |
|---|---|---|---|
| `gpt-4.1` | `OpenAI` | DataZoneStandard | Account |
| `gpt-oss-120b` | `OpenAI-OSS` | GlobalStandard | Account |
| `Kimi-K2.5` | `MoonshotAI` | GlobalStandard | Account |
| `grok-4-20-reasoning` | `xAI` | GlobalStandard | Account |

Clients choose by model name via a single OpenAI-compatible surface. Endpoints: `/v1/chat/completions` (streaming supported) and `/v1/models`.

#### Adding Models

Add one entry to `var.models` in `openai.tf` and run `terraform apply`. Terraform automatically:
- Creates a new regional Cognitive Account if `region` differs from primary
- Deploys the model (account-scoped via `azurerm_cognitive_deployment`; project-scoped via `azapi_resource`)
- Regenerates and re-injects `config.yaml` with correct env var references
- Updates Container App secrets and env vars

#### Config Injection Approach

`config.yaml` is rendered by Terraform's `templatefile()` from `infra/config.yaml.tpl`, then injected as a Container Apps secret. `custom_auth.py` is read from disk and injected the same way.

- Secrets `config-yaml` and `custom-auth-py` store the rendered/read file contents.
- A secret volume mounts all Container App secrets as files at `/mnt/secrets` inside the LiteLLM container.
- The container entrypoint copies `config-yaml` → `/app/config.yaml` and `custom-auth-py` → `/app/custom_auth.py` into an EmptyDir volume, then `exec`s LiteLLM. No init container required.

#### Authentication

Client API keys and the master key are both validated by `custom_auth.py`:

- **Client keys** — set via `TF_VAR_api_keys` (comma-separated). Injected as `API_KEYS` env var on the container.
- **Master key** — set via `TF_VAR_litellm_master_key`. Use for admin operations; do not distribute to clients.

`custom_auth` runs before LiteLLM's built-in auth and replaces it entirely. The handler accepts both key types. See `docs/CUSTOM_AUTH.md` for key management workflow.

Client header:
```
Authorization: Bearer <api_key>
```

#### Additional Hardening

- `litellm_settings.drop_params: true` — prevents clients from overriding provider credentials.
- DB features disabled (`store_model_in_db: false`, `disable_spend_logs: true`, etc.) — no database in use.

### Notes

- Project-scoped model deployments use `azapi_resource` (type `Microsoft.CognitiveServices/accounts/projects/deployments`). `azurerm_cognitive_deployment` only accepts account-level IDs, not project IDs.
- API key secrets are named `azure-ai-key-<region_short>` (e.g., `azure-ai-key-gwc`). One secret per distinct region in the model map.
