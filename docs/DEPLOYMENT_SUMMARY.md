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
2.  Azure AIServices Cognitive Account (`kind = "AIServices"`) — unified Foundry resource serving both models.
3.  Azure Foundry Project (`azurerm_cognitive_account_project`) — required to deploy `gpt-oss-120b`.
4.  Model deployments: `gpt-4.1` (on the account) and `gpt-oss-120b` (on the project).
5.  Log Analytics Workspace for observability.

#### Model Routing

Both models share the same AIServices account endpoint and API key:

- `gpt-4.1` (via `azure/gpt-4.1` in config.yaml — standard deployment on account)
- `gpt-oss-120b` (via `azure/gpt-oss-120b` in config.yaml — deployment on Foundry project)

Clients choose by model name and use a single OpenAI-compatible surface on the LiteLLM proxy. Endpoints supported are `/v1/chat/completions` (streaming supported) and `/v1/models`.

#### Config Injection Approach (ACA)

We use an init container and an EmptyDir volume to inject `config.yaml` reliably:

- A `secret` named `config-yaml` stores the contents of configuration file.
- An `init_container` (busybox) writes the secret value to `/mnt/config/config.yaml`.
- An `EmptyDir` `volume` named `config-volume` is mounted to both the init container and the main LiteLLM container.
- The main container runs with args `--config /app/config.yaml` and mounts `/app` to the same `config-volume`, making the config available at runtime. Port exposed is 4000.

#### Authentication Model (PoC)

- Configure a single MASTER_KEY via `LITELLM_MASTER_KEY` (Container Apps secret) or `general_settings.master_key` in `config.yaml`.
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

- Both models are fully Terraform-managed via `azurerm_cognitive_deployment` targeting `azurerm_cognitive_account_project.project.id`. No AzAPI workarounds or manual portal steps required.
- `gpt-oss-120b` requires `model.format = "OpenAI-OSS"` and must be deployed into a Foundry project (not the root account). This is reflected in `openai.tf`.
- Single API key (`azure-ai-key` Container Apps secret) covers both models — no separate Foundry key needed.
- MVP will transition to FastAPI gateway using LiteLLM SDK, Table Storage-backed keys, and discovery poller.
