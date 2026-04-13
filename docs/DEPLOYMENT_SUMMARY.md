### Local Environment Setup

Variables are stored in `infra/.env` (gitignored). Use **direnv** to auto-export them on directory entry — install it, add the shell hook, then run `direnv allow`:

```sh
# 1. Install (example for bash)
sudo pacman -S direnv   # or apt install / brew install

# 2. Add hook to ~/.bashrc (or ~/.zshrc), then restart shell
eval "$(direnv hook bash)"

# 3. Create env file and allow
cp infra/example.env infra/.env  # fill in values
direnv allow
```

**Without direnv**, export manually before each session:

```sh
export $(grep -v '^#' infra/.env | grep -v '^$' | xargs)
```

---

### Deployment Summary (PoC: Azure AI Foundry — New Foundry)

This Terraform plan deploys a Proof-of-Concept (PoC) for the AzureLIT OpenAI-compatible gateway. The deployment creates the following resources in the configured region within the AzureLIT-POC resource group:

1.  Azure Container App running the LiteLLM proxy with external HTTPS ingress.
2.  Azure AIServices Cognitive Account (`kind = "AIServices"`) — unified Foundry resource serving all models.
3.  Azure Foundry Project (`azurerm_cognitive_account_project`) — always created; required by models with `project = true`.
4.  Model deployments driven by `var.models` map. Currently: `gpt-4.1`, `gpt-oss-120b`, `Kimi-K2.5`, `grok-4-20-reasoning` — all account-scoped on the primary account.
5.  Log Analytics Workspace for observability.

#### Model Routing

All current models share the same AIServices account endpoint and API key (`azure-ai-key-gwc` Container Apps secret):

| Model | Format | SKU | Scoped to |
|---|---|---|---|
| `gpt-4.1` | `OpenAI` | DataZoneStandard | Account |
| `gpt-oss-120b` | `OpenAI-OSS` | GlobalStandard | Account |
| `Kimi-K2.5` | `MoonshotAI` | GlobalStandard | Account |
| `grok-4-20-reasoning` | `xAI` | GlobalStandard | Account |

Clients choose by model name and use a single OpenAI-compatible surface on the LiteLLM proxy. Endpoints supported are `/v1/chat/completions` (streaming supported) and `/v1/models`.

#### Adding Models

Add one entry to `var.models` in `openai.tf` and run `terraform apply`. Terraform automatically:
- Creates a new regional Cognitive Account if `region` differs from primary
- Deploys the model (account-scoped via `azurerm_cognitive_deployment`; project-scoped via `azapi_resource` — `azurerm_cognitive_deployment` does not accept project IDs)
- Regenerates and re-injects `config.yaml` with correct env var references
- Updates Container App secrets and env vars

#### Config Injection Approach (ACA)

`config.yaml` is rendered by Terraform's `templatefile()` from `infra/config.yaml.tpl`, then injected as a Container Apps secret:

- A `secret` named `config-yaml` stores the rendered config contents.
- An `init_container` (busybox) writes the secret value to `/mnt/config/config.yaml`.
- An `EmptyDir` `volume` named `config-volume` is mounted to both the init container and the main LiteLLM container.
- The main container runs with args `--config /app/config.yaml` and mounts `/app` to the same `config-volume`. Port exposed is 4000.

#### Authentication Model (PoC)

- Configure a single MASTER_KEY via `LITELLM_MASTER_KEY` (Container Apps secret) or `general_settings.master_key` in `config.yaml.tpl`.
- With a MASTER_KEY set, LiteLLM enforces client authentication automatically: clients must include the master key in the Authorization header.

Client requirement:
```
Authorization: Bearer sk-<LITELLM_MASTER_KEY>
```

#### Additional Hardening

- `litellm_settings.drop_params: true` prevents clients from overriding provider credentials.
- DB-related features disabled to keep the PoC DB-less (`store_model_in_db: false`, `disable_spend_logs: true`, `disable_spend_updates: true`, `disable_reset_budget: true`).
- Several `general_settings` entries (`forward_client_headers_to_llm_api`, `disable_adding_master_key_hash_to_db`, `allow_requests_on_db_unavailable`) are commented out with a TODO — enable only after testing, as they have been observed to break auth.

### Notes

- Project-scoped model deployments use `azapi_resource` (type `Microsoft.CognitiveServices/accounts/projects/deployments`). `azurerm_cognitive_deployment` only accepts account-level IDs, not project IDs.
- `gpt-oss-120b` is currently deployed account-scoped with `GlobalStandard` SKU. Project-scoped deployment via AzAPI hangs in Germany West Central (likely region API instability).
- API key secrets are named `azure-ai-key-<region_short>` (e.g., `azure-ai-key-gwc`). One secret per distinct region in the model map.
- MVP will transition to FastAPI gateway using LiteLLM SDK, Table Storage-backed keys, and discovery poller.
