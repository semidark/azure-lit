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

### Budget Configuration

The deployment includes an Azure Consumption Budget that monitors costs and sends email alerts when spending thresholds are reached.

**Required** (no default):
```sh
# Comma-separated list of email addresses for budget alerts
TF_VAR_budget_alert_emails="admin@company.com,devops@company.com"
```

**Optional** (default: 100 EUR):
```sh
# Monthly budget limit in EUR
TF_VAR_budget_monthly_amount=500
```

**Budget alerts trigger at:**
- **50%** of budget — warning notification
- **80%** of budget — elevated notification
- **100%** of budget — critical notification (budget exhausted)

The budget only tracks costs within the Terraform-managed resource group. The subscription Owner and Contributor roles also receive alerts automatically.

---

### Deployment Summary

This Terraform plan deploys an OpenAI-compatible LiteLLM Proxy gateway on Azure Container Apps, fronting Azure AI Foundry model deployments. The deployment creates the following resources:

1. Azure Container App running the LiteLLM Proxy with external HTTPS ingress.
2. Azure AIServices Cognitive Account (`kind = "AIServices"`) — unified Foundry resource serving all models.
3. Azure Foundry Project (`azurerm_cognitive_account_project`) — always created; required by models with `project = true`.
4. Model deployments driven by `var.models` map in `infra/openai.tf` (repo-maintained example set; customize per subscription/region/SKU availability).
5. Log Analytics Workspace for observability.
6. Azure Consumption Budget with email alerts at 50%, 80%, and 100% thresholds.

#### Model Routing

Most models share the primary AIServices account endpoint and API key (`azure-ai-key-gwc` Container Apps secret). Models in non-primary regions use region-specific accounts and secrets (for example, `azure-ai-key-swc` for Sweden Central).

| Model (example snapshot) | Format | SKU | Region | API Surface |
|---|---|---|---|---|
| `gpt-4.1` | `OpenAI` | DataZoneStandard | germanywestcentral | Chat Completions |
| `gpt-oss-120b` | `OpenAI-OSS` | GlobalStandard | germanywestcentral | Chat Completions |
| `Kimi-K2.5` | `MoonshotAI` | GlobalStandard | germanywestcentral | Chat Completions |
| `grok-4-20-reasoning` | `xAI` | GlobalStandard | germanywestcentral | Chat Completions |
| `gpt-5.4` | `OpenAI` | GlobalStandard | germanywestcentral | Chat Completions |
| `gpt-5.3-codex` | `OpenAI` | GlobalStandard | swedencentral | Responses API only |

Clients choose by model name via a single OpenAI-compatible surface. Standard chat models use `/v1/chat/completions` (streaming supported). Responses-only models such as `gpt-5.3-codex` are wired with LiteLLM's `azure/responses/` prefix and `api_version=preview`.

The model list above is an example snapshot for documentation context and may drift from the current Terraform source. Actual deployability varies by subscription, region, quota, and Azure rollout stage. Treat `infra/openai.tf` and Azure CLI model discovery as operational truth.

#### Choosing Deployable Models

Do not assume a model family/version/SKU is deployable in your subscription. Use the helper first:

```sh
cd infra
./list-deployable-models.sh --name gpt-5 --capability responses
```

Then copy exact `name`, `version`, and `sku` values into `var.models`.

If `responses=true` and `chatCompletion=false`, set `responses_only = true`.

#### Adding Models

Add one entry to `var.models` in `openai.tf` and run `terraform apply`. Terraform automatically:
- Creates a new regional Cognitive Account if `region` differs from primary
- Deploys the model (account-scoped via `azurerm_cognitive_deployment`; project-scoped via `azapi_resource`)
- Uses the Responses API wiring automatically when `responses_only = true`
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
- `litellm_settings.drop_unknown_params: true` — strips unknown request fields before proxying upstream.
- DB features disabled (`store_model_in_db: false`, `disable_spend_logs: true`, etc.) — no database in use.
- Admin UI and key-management routes disabled (`disable_admin_ui: true`, `disable_key_management: true`).
- Container image pinned to `ghcr.io/berriai/litellm:main-v1.82.3`, HTTPS-only ingress, `min_replicas = 0`, `max_replicas = 1`, and `cooldown_period_in_seconds = 600`.

#### Prompt Caching

Azure OpenAI models (`gpt-4.1`, `gpt-5.4`, `gpt-5.1-codex`) support automatic prompt caching. Key points:

- **Automatic activation**: No configuration required; works for prompts with 1024+ tokens
- **Parameter passthrough**: `prompt_cache_key` and `prompt_cache_retention` survive `drop_unknown_params: true` filtering
- **Cost impact**: Cached tokens billed at ~10-20% of standard input pricing
- **Verification**: Check `usage.prompt_tokens_details.cached_tokens` in responses; monitor via Log Analytics `CachedTokensIn_d` field

See [docs/PROMPT_CACHING.md](PROMPT_CACHING.md) for detailed guidance and best practices.

### Notes

- Project-scoped model deployments use `azapi_resource` (type `Microsoft.CognitiveServices/accounts/projects/deployments`). `azurerm_cognitive_deployment` only accepts account-level IDs, not project IDs.
- API key secrets are named `azure-ai-key-<region_short>` (e.g., `azure-ai-key-gwc`). One secret per distinct region in the model map.
