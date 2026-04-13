# AGENTS.md — AzureLIT

Planning + infra repo for an OpenAI-compatible LiteLLM gateway on Azure. No application source code, tests, or CI yet — only Terraform IaC and design docs.

## Repo Layout

- `infra/` — Terraform root module (all IaC lives here; run commands from this dir)
  - `main.tf` — Providers, variables, core resources (RG, Log Analytics, Container Apps)
  - `openai.tf` — Azure AIServices Cognitive Account (unified Foundry), Foundry project, model deployments
  - `kv.tf` — Comment-only file; Key Vault removed (no longer required)
  - `config.yaml.tpl` — LiteLLM Proxy config template; rendered by Terraform `templatefile()` and injected into container at deploy time
  - `custom_auth.py` — Custom auth handler; validates Bearer tokens against `API_KEYS` env var + master key
  - `outputs.tf` — Container App FQDN and URL
- `docs/` — Design docs
  - `PRD.md` — Full MVP product requirements
  - `POC.md` — Current deployment approach and architecture
  - `LINKS.md` — Curated external references (LiteLLM, Azure, Terraform)
  - `DEPLOYMENT_SUMMARY.md`, `MASTER_KEY_MANAGEMENT.md`, `CUSTOM_AUTH.md` — Operational docs
  - `PG_SIDECAR_FINDINGS.md` — Investigation into PostgreSQL sidecar approach (abandoned)

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
| `litellm_master_key` | `TF_VAR_litellm_master_key` | Admin key; must start with `sk-` |
| `api_keys` | `TF_VAR_api_keys` | Comma-separated client API keys validated by `custom_auth.py` |

### Variables with Defaults

| Variable | Default |
|---|---|
| `location` | `germanywestcentral` |
| `resource_group_name` | `AzureLIT-POC` |
| `models` | See `openai.tf` — map of all model deployments |

### Providers

- `azurerm` >= 4.55.0 (locked at 4.68.0)
- `azapi` >= 2.0 (locked at 2.9.0)

## Architecture

LiteLLM Proxy runs as a Container App with external HTTPS ingress on port 4000.

- **Config injection**: An init container writes `config.yaml` and `custom_auth.py` from Container Apps secrets into an EmptyDir volume mounted at `/app`. Changes to either require redeploy (`terraform apply`).
- **Auth**: `custom_auth.py` validates Bearer tokens against client API keys (`API_KEYS` env var) and the master key (`LITELLM_MASTER_KEY`). No DB, no virtual keys, no Admin UI.
- **Models**: Defined in `var.models` map in `openai.tf`. Currently: `gpt-4.1`, `gpt-oss-120b`, `Kimi-K2.5`, `grok-4-20-reasoning` — all on the primary AIServices account. Adding a model = one map entry + `terraform apply`.
- **Container image**: `ghcr.io/berriai/litellm:main-stable`

## Secrets & Env

- `.env` and `*.tfvars` are gitignored — never commit secrets.
- Container Apps secrets:
  - `config-yaml` — rendered LiteLLM config
  - `custom-auth-py` — `custom_auth.py` source, injected alongside config
  - `litellm-master-key` — admin key
  - `api-keys` — comma-separated client API keys
  - `azure-ai-key-<region>` — one per distinct region in model map (e.g., `azure-ai-key-gwc`)

### Variable Injection for Terraform

`TF_VAR_*` variables are stored in `infra/.env` (gitignored). The repo uses **direnv** to auto-export them on directory entry — install it, hook it into your shell (`eval "$(direnv hook zsh)"`), then run `direnv allow`. **The shell hook is required; installing direnv alone is not enough.**

Without direnv, export manually before each session:
```sh
export $(grep -v '^#' infra/.env | grep -v '^$' | xargs)
```

Full setup in `docs/DEPLOYMENT_SUMMARY.md`.

## Gotchas

- `config.yaml.tpl` or `custom_auth.py` changes only take effect on redeploy — no hot reload.
- `litellm_settings.drop_params: true` — prevents clients from overriding provider credentials at request time.
- `custom_auth.py` caches valid keys in memory on first request. Key changes require redeploy to take effect.
- `custom_auth` replaces LiteLLM's built-in master key check entirely — the handler explicitly also accepts `LITELLM_MASTER_KEY` so admin operations keep working.
- No content logging (prompts/responses); metadata-only with 30-day retention in Log Analytics.
- The init container pattern adds cold-start latency (TODO in `main.tf` to remove).

## Next Steps

- Per-key model access restrictions (extend `custom_auth.py` to map keys → allowed models)
- Spend tracking / rate limiting without DB (e.g. Azure Table Storage counters)
- Telemetry to Azure Monitor (latency, errors, token counts)
- Remove init container pattern — bake config into image or use secret volume mounts directly
