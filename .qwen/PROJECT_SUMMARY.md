# Project Summary

## Overall Goal
Deliver a lightweight, cost-conscious, OpenAI-compatible gateway that unifies Azure OpenAI deployments and Azure AI Foundry serverless endpoints behind a single API surface, with streaming support and minimal operational overhead.

## Key Knowledge
- Technology/Approach
  - PoC: Use the official LiteLLM Proxy container on Azure Container Apps with external HTTPS ingress.
  - MVP: Custom HTTP service (e.g., FastAPI) using LiteLLM SDK; Table Storage-backed key validation; model discovery poller; unified routing across Azure OpenAI and Azure AI Foundry.
  - IaC: Terraform for provisioning (Resource Group, Container Apps Environment/App, Log Analytics; optional Key Vault).
  - Region default: Sweden Central (configurable later).
- Endpoints & Streaming
  - OpenAI-compatible: `/v1/chat/completions` (streaming supported) and `/v1/models`.
  - Streaming: Clients set `stream=true`; Proxy returns OpenAI-style `chat.completion.chunk` events.
- Authentication (Critical)
  - PoC auth is MASTER_KEY-only. When `LITELLM_MASTER_KEY` or `general_settings.master_key` is set, clients MUST send `Authorization: Bearer <MASTER_KEY>`; key should start with `sk-`.
  - Without a database: all clients share the same credential; no virtual keys, budgets, per-user permissions, or Admin UI.
  - If no MASTER_KEY is set: proxy is unauthenticated (acceptable only for local development).
  - Custom Auth: Not used in PoC; reserved for future to validate against a custom store (e.g., Table Storage) or add extra checks.
- Configuration & Conventions
  - Models via `config.yaml` `model_list`, mapping `model_name` to Azure provider:
    - `litellm_params`: `model: azure/<deployment>`, `api_base: os.environ/AZURE_API_BASE`, `api_key: os.environ/AZURE_API_KEY`, `api_version: os.environ/AZURE_API_VERSION`.
  - LiteLLM settings hardening:
    - `litellm_settings.drop_params: true` to prevent overriding provider credentials.
    - `forward_client_headers_to_llm_api: false`.
    - DB features disabled: `store_model_in_db: false`, `disable_spend_logs: true`, `disable_spend_updates: true`, `disable_adding_master_key_hash_to_db: true`, `disable_reset_budget: true`, `allow_requests_on_db_unavailable: true`, `timeout: 60`.
  - Port: 4000.
  - Config injection on ACA: init container writes `config.yaml` from secrets to an EmptyDir volume mounted at `/app/config.yaml`.
- Security/Logging
  - Use Container Apps secrets for `AZURE_API_KEY` and `LITELLM_MASTER_KEY`; avoid committing secrets.
  - HTTPS-only; no prompt/response content logging (metadata-only, 90-day retention).
  - Key Vault is optional in PoC, planned for MVP provider secrets.
- Naming/UX
  - Model naming follows Foundry shortnames (e.g., gpt-5, o3-mini), optional internal prefixes.
- Build/Testing
  - No build/test tooling yet (no application code). Validation via curl/OpenAI SDK hitting the proxy.

## Recent Actions
- Validated SME guidance: MASTER_KEY alone enforces client authentication on LiteLLM Proxy (confirmed by testing).
- Documentation updates and alignment (committed):
  - POC.md: Clarified MASTER_KEY-only auth; Authorization header format; `sk-` requirement; DB-less limitations.
  - MASTER_KEY_MANAGEMENT.md: Explained enforcement behavior; rotation; behavior without master key; production path to DB/virtual keys.
  - CUSTOM_AUTH.md: Stated PoC does not use custom_auth; when to reintroduce it; pointed to virtual keys for multi-tenant.
  - DEPLOYMENT_SUMMARY.md: Updated to MASTER_KEY-only auth; removed custom_auth enforcement; noted hardening settings.
  - PRD.md: Aligned PoC (MASTER_KEY-only) vs MVP (Table Storage-backed keys).
- Git
  - Created a single commit that updates the above docs; branch is ahead of origin by 1 commit (not pushed).

## Current Plan
1. [DONE] Audit and update docs to reflect MASTER_KEY-only authentication and remove PoC custom_auth references.
2. [DONE] Clarify Authorization header usage and `sk-` key requirement across docs.
3. [DONE] Align PRD with PoC vs MVP auth approaches (PoC: MASTER_KEY-only; MVP: DB-backed keys/Table Storage).
4. [TODO] Push the documentation changes to origin/main (awaiting user confirmation).
5. [TODO] Continue PoC validation:
   - Test streaming behavior with client SDKs against ACA ingress.
   - Confirm model_list mapping and Azure provider configuration.
6. [TODO] MVP implementation (per PRD):
   - Build FastAPI gateway using LiteLLM SDK for `/v1/chat/completions` and `/v1/models`.
   - Implement Table Storage-backed key store and request-time Bearer validation.
   - Implement discovery poller for Azure AI Foundry; maintain model catalog in Table Storage.
   - Wire telemetry (requests, errors, latency percentiles, token counts) to Azure Monitor.
   - Harden Terraform modules (Container Apps, Table Storage, Key Vault for provider secrets, Monitor), parameterize region and API versions.
7. [TODO] Security/ops hardening:
   - Consider IP allowlists on ingress for PoC.
   - Confirm no prompt/response logging; maintain metadata-only logs.

---

## Summary Metadata
**Update time**: 2025-10-14T16:03:49.871Z 
