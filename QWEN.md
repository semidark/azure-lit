# QWEN.md — Project Guide for AzureLIT

This document provides concise, high-signal guidance for working in this repository. It is intended as operational context for Qwen Code and collaborators during future sessions.

## Project Type

Planning + implementation repository in early stages. Purpose: design and deploy an OpenAI-compatible gateway on Azure (LiteLLM-based). As of now, no application source code, tests, or build tooling are present yet; these will be added in this repo as implementation proceeds.

## Directory Overview

- `docs/`
  - `PRD.md` — Product Requirements Document for an OpenAI-compatible gateway unifying Azure OpenAI and Azure AI Foundry behind a single API surface using LiteLLM. Captures objectives, scope, decisions, architecture, requirements, deployment, roadmap, and risks.
  - `POC.md` — Proof-of-Concept plan using the stock LiteLLM Proxy in Azure Container Apps with minimal infrastructure and a config-driven model list. Emphasizes external HTTPS ingress, streaming support, single master key approach for PoC, and Terraform-based provisioning.
  - `LINKS.md` — Curated references for LiteLLM, Azure AI Foundry, Azure OpenAI, Azure infra (Container Apps, Key Vault, Table Storage, Monitor), Terraform, streaming, and a sample community repo for Terraform-based LiteLLM deploys.

## High-Level Vision (from PRD)

- A lightweight, cost-conscious, OpenAI-compatible HTTP gateway exposing `/v1/chat/completions` (with streaming) and `/v1/models`.
- Unify routing across Azure OpenAI deployments and Azure AI Foundry serverless endpoints.
- Automatic model discovery (poller) with a simple catalog in Azure Table Storage.
- Single-tenant API key validation stored in Table Storage; provider secrets in Key Vault.
- Low-ops runtime on Azure Container Apps; observability in Azure Monitor; Terraform for IaC.

## PoC vs. MVP

- PoC (docs/POC.md):
  - Use official LiteLLM Proxy container; configure via `config.yaml` + env vars.
  - External ingress on Azure Container Apps; minimal secrets via Container Apps secrets; region default Sweden Central.
  - Single master key concept (enforced via ingress controls or reverse proxy if needed).
  - No discovery; model list updated through redeploys.

- MVP (docs/PRD.md):
  - Custom HTTP service (e.g., FastAPI) using LiteLLM SDK; OpenAI-compatible streaming; error normalization.
  - `/v1/chat/completions`, `/v1/models`, discovery poller, unified routing across Azure OpenAI + Foundry.
  - Table Storage-backed key store and catalog; secrets in Key Vault; metrics to Azure Monitor; Terraform CI/CD.

## Intended Usage of This Repository

- Source of truth for requirements, architecture, and operational decisions.
- Shared repository for implementation (service code, infra modules, tests) as the project evolves.
- Reference hub of authoritative links for engineers during development.

## Getting Started (for Implementers)

1. Read `docs/PRD.md` end-to-end to understand MVP scope and decisions.
2. Use `docs/POC.md` to stand up a minimal LiteLLM proxy on Azure Container Apps to validate client compatibility and streaming.
3. Capture findings (latency, streaming behavior, error mapping) and update the PRD as needed.
4. Begin implementation directly in this repository using the Suggested Next Structure below.

## Suggested Next Structure (as code is added)

- `app/` — Gateway service code (e.g., FastAPI + LiteLLM SDK)
- `infra/` — Terraform modules and envs (Container Apps, Table Storage, Key Vault, Monitor)
- `ops/` — Runbooks, dashboards, alerts
- `tests/` — Unit/integration tests; streaming behavior tests
- `docs/` — Keep PRD/POC/links; add ADRs for decisions

## Key Operational Assumptions

- Region default: Sweden Central (configurable later).
- No content logging (prompts/responses). Metadata-only logs with 90-day retention.
- Model naming follows Foundry shortnames (e.g., gpt-5, o3-mini) with optional internal prefixes.
- API versioning defaults to latest for providers but must be configurable.

## Risks to Track

- Discovery variability across Foundry deployments; may require manual overrides.
- Streaming parity with OpenAI clients; validate early with SDKs.
- Secret management cost vs. security posture; start with essentials in Key Vault for MVP.
- Provider API version drift; monitor and update.

## Actionable TODOs for Implementation Here

- Implement `/v1/chat/completions` and `/v1/models` with LiteLLM SDK and OpenAI-compatible streaming.
- Table Storage-backed API key validation middleware.
- Discovery poller for Foundry deployments; maintain catalog in Table Storage.
- Telemetry to Azure Monitor: requests, errors, latency percentiles, token counts.
- Terraform for Container Apps, Table Storage, Key Vault, Monitor; parameterize region and API versions.

## Important Links (inline)

### LiteLLM
- LiteLLM Official Docs: https://docs.litellm.ai/docs/
- LiteLLM GitHub Repository: https://github.com/BerriAI/litellm
- LiteLLM Proxy Getting Started: https://docs.litellm.ai/docs/proxy/getting_started
- LiteLLM Model Management (Proxy): https://docs.litellm.ai/docs/proxy/model_management
- Supported Providers: https://docs.litellm.ai/docs/providers
- Model Metadata Database: https://models.litellm.ai/

### Azure AI Foundry
- Overview: https://ai.azure.com/doc/
- Concept Docs: https://learn.microsoft.com/en-us/azure/ai-foundry/
- List Deployments (REST): https://learn.microsoft.com/en-us/rest/api/aifoundry/aiprojects/deployments/list?view=rest-aifoundry-aiprojects-v1
- Endpoints Concepts: https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-models/concepts/endpoints
- Models Overview: https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/foundry-models-overview
- Models sold directly by Azure: https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-models/concepts/models-sold-directly-by-azure

### Azure OpenAI Service
- Service Overview: https://learn.microsoft.com/en-us/azure/ai-services/openai/
- REST API Reference: https://learn.microsoft.com/en-us/azure/ai-services/openai/reference

### Azure Infrastructure & Services
- Azure Container Apps: https://learn.microsoft.com/en-us/azure/container-apps/
- Azure Key Vault (Secrets): https://learn.microsoft.com/en-us/azure/key-vault/general/
- Azure Table Storage: https://learn.microsoft.com/en-us/azure/storage/tables/table-storage-overview
- Azure Monitor: https://learn.microsoft.com/en-us/azure/azure-monitor/
- Azure DevOps Pipelines (CI/CD): https://learn.microsoft.com/en-us/azure/devops/pipelines/
- Terraform Azure Provider: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs

### General AI/LLM and Streaming
- OpenAI API Streaming: https://platform.openai.com/docs/guides/streaming-responses
- OpenAI Model Listing: https://platform.openai.com/docs/models

### Community Example
- Terraform setup for LiteLLM on Azure (uses Postgres; serves as a helpful reference even if we avoid DB): https://github.com/pexxi/litellm-azure-tf-deploy

---

Maintenance note: As more files or source code are added, update this QWEN.md with build/test commands, language/tooling, and coding conventions specific to the growing codebase.