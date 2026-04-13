### Deployment Summary (PoC: Azure OpenAI + Azure AI Foundry)

This Terraform plan deploys a Proof-of-Concept (PoC) for the AzureLIT OpenAI-compatible gateway. The deployment creates the following resources in the configured region within the AzureLIT-POC resource group:

1.  Azure Container App running the LiteLLM proxy with external HTTPS ingress.
2.  Azure AI Foundry Hub and Project for model management.
3.  Azure OpenAI resource + deployment for gpt-4.1.
4.  Azure Storage Account and Azure Key Vault used by AI Foundry Hub.
5.  Log Analytics Workspace for observability.

#### Model Routing

- Azure OpenAI: `gpt-4.1` (via `azure/gpt-4.1` provider in config.yaml)
- Azure AI Foundry: `gpt-oss-120b` (via `azure_ai/gpt-oss-120b` provider in config.yaml)

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
- `forward_client_headers_to_llm_api: false`.
- DB-related features disabled to keep the PoC DB-less (`store_model_in_db: false`, `disable_spend_logs: true`, `disable_spend_updates: true`, `disable_adding_master_key_hash_to_db: true`, `disable_reset_budget: true`, `allow_requests_on_db_unavailable: true`).

### Notes

- AzureRM provider does not currently expose a deployment resource for Azure AI Foundry Projects. As a PoC workaround, we inject Foundry project credentials and configure the LiteLLM proxy to route requests to the Foundry project endpoint directly.
- If you need Terraform-managed Foundry deployments, use AzAPI with data-plane actions once official support is available, or perform manual deployment in the Foundry portal and reference the endpoint/key here.
- MVP will transition to FastAPI gateway using LiteLLM SDK, Table Storage-backed keys, and discovery poller.
