# AGENTS.md — AzureLIT

Planning + infra repo for an OpenAI-compatible LiteLLM gateway on Azure. No application source code, tests, or CI yet — only Terraform IaC and design docs.

## Repo Layout

- `infra/` — Terraform root module (all IaC lives here; run commands from this dir)
  - `main.tf` — Providers, variables, core resources (RG, Storage, Key Vault, AI Foundry, Container Apps)
  - `openai.tf` — Azure OpenAI Cognitive Account + gpt-4.1 deployment
  - `kv.tf` — Key Vault secret for Foundry API key (**placeholder value "REPLACE-ME"** — must be set manually before apply)
  - `config.yaml` — LiteLLM Proxy config; injected into container at deploy time
  - `custom_auth.py` — Future custom auth handler (not wired in PoC)
  - `outputs.tf` — Container App FQDN and URL
- `docs/` — Design docs
  - `PRD.md` — Full MVP product requirements
  - `POC.md` — Current PoC deployment approach
  - `LINKS.md` — Curated external references (LiteLLM, Azure, Terraform)
  - `DEPLOYMENT_SUMMARY.md`, `MASTER_KEY_MANAGEMENT.md`, `CUSTOM_AUTH.md` — Operational docs

## Terraform Commands

All commands run from `infra/`:

```sh
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Required Variables (no defaults)

| Variable | How to set | Purpose |
|---|---|---|
| `subscription_id` | `TF_VAR_subscription_id` | Azure subscription to deploy into |
| `litellm_master_key` | `TF_VAR_litellm_master_key` | Client auth key (Bearer token); should start with `sk-` |

### Variables with Defaults

| Variable | Default |
|---|---|
| `location` | `Germany West Central` |
| `resource_group_name` | `AzureLIT-POC` |
| `ai_foundry_hub_name` | `AzureLIT-Hub` |
| `ai_foundry_project_name` | `AzureLIT-Project` |

### Providers

- `azurerm` >= 3.0 (locked at 4.48.0)
- `azapi` >= 2.0 (locked at 2.7.0)
- `random` (implicit)

## Architecture (PoC)

LiteLLM Proxy runs as a Container App with external HTTPS ingress on port 4000.

- **Config injection**: An init container writes `config.yaml` from a Container Apps secret into an EmptyDir volume mounted at `/app`. Config changes require redeploy.
- **Auth**: MASTER_KEY-only. Clients send `Authorization: Bearer <key>`. No DB, no virtual keys, no Admin UI.
- **Models**: `gpt-4.1` (Azure OpenAI, `azure/` provider) and `gpt-oss-120b` (AI Foundry, `azure_ai/` provider).
- **Container image**: `ghcr.io/berriai/litellm:main-stable`

## Secrets & Env

- `.env` and `*.tfvars` are gitignored — never commit secrets.
- Container Apps secrets: `config-yaml`, `azure-openai-key`, `litellm-master-key`, `azure-foundry-api-key`.
- `kv.tf` has a placeholder secret value — replace before first apply or set manually in Key Vault after.

## Gotchas

- `config.yaml` changes only take effect on redeploy (no hot reload).
- `litellm_settings.drop_params: true` — prevents clients from overriding provider credentials at request time.
- Several `general_settings` entries are commented out with a TODO about breaking auth; don't enable without testing.
- No content logging (prompts/responses); metadata-only with 30-day retention in Log Analytics.
- The init container pattern adds cold-start latency (marked TODO in `main.tf` to remove).

## Next Steps (per PRD)

When implementation begins, expected structure:
- `app/` — FastAPI gateway using LiteLLM SDK
- `tests/` — Unit/integration tests
- `ops/` — Runbooks, dashboards

Read `docs/PRD.md` for full MVP scope; `docs/POC.md` for current state.
