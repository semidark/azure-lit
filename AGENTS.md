# AGENTS.md — AzureLIT

Planning + infra repo for an OpenAI-compatible LiteLLM gateway on Azure. No application source code, tests, or CI yet — only Terraform IaC and design docs.

## Repo Layout

- `infra/` — Terraform root module (all IaC lives here; run commands from this dir)
  - `main.tf` — Providers, variables, core resources (RG, Log Analytics, Container Apps)
  - `openai.tf` — Azure AIServices Cognitive Account (unified Foundry), Foundry project, gpt-4.1 + gpt-oss-120b deployments
  - `kv.tf` — Comment-only file; Key Vault removed (no longer required by new Foundry)
  - `config.yaml.tpl` — LiteLLM Proxy config template; rendered by Terraform `templatefile()` and injected into container at deploy time
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
| `location` | `germanywestcentral` |
| `resource_group_name` | `AzureLIT-POC` |
| `models` | See `openai.tf` — map of all model deployments |

### Providers

- `azurerm` >= 4.55.0 (locked at 4.68.0)
- `azapi` >= 2.0 (locked at 2.9.0)
- `random` (implicit)

## Architecture (PoC)

LiteLLM Proxy runs as a Container App with external HTTPS ingress on port 4000.

- **Config injection**: An init container writes `config.yaml` from a Container Apps secret into an EmptyDir volume mounted at `/app`. Config changes require redeploy.
- **Auth**: MASTER_KEY-only. Clients send `Authorization: Bearer <key>`. No DB, no virtual keys, no Admin UI.
- **Models**: Defined in `var.models` map in `openai.tf`. Currently: `gpt-4.1`, `gpt-oss-120b`, `Kimi-K2.5`, `grok-4-20-reasoning` — all on the primary AIServices account (`azure/` provider). Adding a model = one map entry + `terraform apply`.
- **Container image**: `ghcr.io/berriai/litellm:main-stable`

## Secrets & Env

- `.env` and `*.tfvars` are gitignored — never commit secrets.
- Container Apps secrets: `config-yaml`, `litellm-master-key`, and one `azure-ai-key-<region>` secret per distinct region in the model map (e.g., `azure-ai-key-gwc` for Germany West Central).

### Variable Injection for Terraform

`TF_VAR_*` variables are stored in `infra/.env` (gitignored). The repo uses **direnv** to auto-export them on directory entry — install it, hook it into your shell (`eval "$(direnv hook bash)"`), then run `direnv allow`. **The shell hook is required; installing direnv alone is not enough.**

Without direnv, export manually before each session:
```sh
export $(grep -v '^#' infra/.env | grep -v '^$' | xargs)
```

Full setup in `docs/DEPLOYMENT_SUMMARY.md`.

## Gotchas

- `config.yaml.tpl` changes only take effect on redeploy (no hot reload).
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
