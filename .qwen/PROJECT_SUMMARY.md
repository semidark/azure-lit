# Project Summary

## Overall Goal
Design and deploy a lightweight, OpenAI-compatible HTTP gateway on Azure using LiteLLM, exposing `/v1/chat/completions` (with streaming) and `/v1/models`, unifying access to Azure OpenAI and Azure AI Foundry, with cost-conscious, low-ops infrastructure on Azure Container Apps and Terraform for IaC.

## Key Knowledge
- Tech stack and infra
  - Azure Container Apps for runtime; Azure Resource Group, Storage Account, Key Vault, Log Analytics, Container App Environment provisioned via Terraform.
  - Azure OpenAI: Cognitive Account + deployment (gpt-4.1) in Germany West Central.
  - Azure AI Foundry: Hub and Project created (for future discovery/poller work).
  - Terraform providers: `hashicorp/azurerm v4.47.0` (+ `hashicorp/random v3.7.2`); state migration from Sweden Central to Germany West Central completed/in-progress for resources.
  - Region: Germany West Central (migrated from Sweden Central).
- Service configuration and runtime
  - Image: LiteLLM proxy Docker image; moved to stable tag `ghcr.io/berriai/litellm:v1.75.8-stable` (main-latest caused entrypoint failures).
  - Command: explicitly run `litellm` CLI with args `--config /app/config.yaml --port 4000 --host 0.0.0.0` (stable start with Uvicorn).
  - Config injection: init container writes `config.yaml` from Container Apps secret into an EmptyDir shared volume; main container mounts it at `/app`.
  - Ingress: external enabled, `target_port = 4000`.
  - Environment variables:
    - `LITELLM_MASTER_KEY`: currently a placeholder (must be secured).
    - `AZURE_OPENAI_API_BASE`: set to `https://azurelit-openai.openai.azure.com/` (resource-specific endpoint, not the regional cognitive endpoint).
    - `AZURE_OPENAI_API_VERSION`: currently `2025-04-01` (previously `2024-10-21`).
    - `AZURE_OPENAI_API_KEY`: injected from Container Apps secret wired to the Cognitive Account primary key.
- LiteLLM config (`infra/config.yaml`)
  - DB-less `model_list` with `azure-gpt-4.1` mapped to `azure/gpt-4.1` using env-based `api_base`, `api_key`, `api_version`.
  - `general_settings`: master key via env; DB features disabled; allow proxy operation without DB.
- Conventions
  - Use Terraform for all infra changes; avoid introducing separate provider blocks that duplicate `required_providers`.
  - Resource names include deterministic names and random suffix for globally unique storage account.
  - Prefer stable LiteLLM images and explicit command/args to avoid image entrypoint regressions.
- Operational details
  - FQDN example: `litellm-proxy.wittyhill-038bf8ee.germanywestcentral.azurecontainerapps.io`.
  - Verification commands:
    - Terraform: `terraform init`, `terraform apply -auto-approve`.
    - Azure CLI: `az containerapp show`, `az containerapp revision list`, `az containerapp logs show --type system|console`.
    - API tests: `curl` against root, `/v1/models`, and `/v1/chat/completions` with `Authorization: Bearer <master-key>`.

## Recent Actions
- Fixed Terraform initialization errors:
  - Removed duplicate `providers.tf` block; consolidated `required_providers` in `main.tf`.
  - Added `hashicorp/random` provider usage in existing configuration to suffix storage account names.
- Imported already-existing resources into Terraform state:
  - Key Vault (`AzureLIT-POC-KV`), Log Analytics (`AzureLIT-POC-LA`), Cognitive Account (`azurelit-openai`) imported to resolve “resource exists” apply conflicts.
- Provisioned in Germany West Central:
  - Recreated Storage Account with random suffix.
  - Created Container App Environment (`AzureLIT-POC-CAE`).
  - Created Azure AI Foundry Hub (`AzureLIT-Hub`) and Project (`AzureLIT-Project`).
- Azure OpenAI deployment:
  - gpt-4.1 failed with `latest` version; successfully deployed with `version = "2025-04-14"` (GlobalStandard).
- Container App stabilization:
  - Initial failures due to missing `docker/prod_entrypoint.sh` in `main-latest` image; resolved by:
    - Switching to stable image `v1.75.8-stable`.
    - Overriding command to `litellm` and explicit args (`--config`, `--port`, `--host`).
  - Verified healthy startup via logs (Uvicorn listening on `0.0.0.0:4000`), Swagger root available.
  - `/v1/models` returns the `azure-gpt-4.1` model as configured.
- API testing status:
  - `/v1/chat/completions` returning `500` with `litellm.APIConnectionError: AzureException APIConnectionError - Connection error` when calling `azure-gpt-4.1`.
  - Enabled `--detailed_debug` and updated `AZURE_OPENAI_API_VERSION` to `2025-04-01` to aid troubleshooting.
  - Logs show OpenAI SDK APIConnectionError during call to Azure OpenAI Chat Completions.

## Current Plan
1. [IN PROGRESS] Resolve Azure OpenAI connection error for chat completions
   - Remove trailing slash from `AZURE_OPENAI_API_BASE` (`https://azurelit-openai.openai.azure.com`).
   - Validate `api_version` compatibility (try `2024-10-21` vs `2025-04-01` based on Azure OpenAI deployment support).
   - Re-test `/v1/chat/completions` with `azure-gpt-4.1`.
2. [TODO] Master key security
   - Replace `your-master-key` with a secure secret; optionally store in Key Vault or Container Apps secret with proper rotation.
3. [TODO] Documentation and commits
   - Update `docs/DEPLOYMENT_SUMMARY.md` with successful region migration, FQDN, and runtime changes (stable image, command override).
   - Commit all infra changes (`openai.tf`, `main.tf`, `config.yaml`) with a clear message focused on why (stability, entrypoint fix, API base correction).
4. [TODO] Additional validation
   - Confirm quota and gpt-4.1 availability in Germany West Central; keep `gpt-4o` fallback ready if needed.
   - Smoke tests: root, `/v1/models`, `/v1/chat/completions` (streaming), with OpenAI-compatible clients.
5. [TODO] Hardening and ops
   - Add basic health probes if needed (readiness on port 4000).
   - Consider Azure Monitor wiring (logs/metrics) via Log Analytics and dashboards.
   - Plan discovery poller + Table Storage key/catalog for MVP in subsequent iterations.

---

## Summary Metadata
**Update time**: 2025-10-13T11:00:54.483Z 
