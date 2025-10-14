# PRD: OpenAI-Compatible Gateway for Azure AI Foundry using LiteLLM SDK

## Objective
- Deliver a lightweight, cost-conscious, OpenAI-compatible HTTP gateway unifying Azure OpenAI deployments and Azure AI Foundry serverless endpoints behind one API surface.
- Focus first on chat completions with streaming, automatic model discovery via polling, and minimal operational overhead.

## Scope (MVP)
- Endpoints:
  - POST /v1/chat/completions (streaming)
  - GET /v1/models
- Authentication:
  - Single-tenant API key auth via custom key store (Azure Table Storage) for MVP
  - PoC uses MASTER_KEY-only authentication (no database, no virtual keys)
- Discovery:
  - Poll Azure AI Foundry to auto-expose models
- Routing:
  - Support both Azure OpenAI and Foundry serverless inference
- Observability:
  - Azure Monitor; no prompt/response content logging; metadata retention 90 days
- Region:
  - Sweden Central by default (configurable)
- CI/CD:
  - Terraform-based deployment

## Users and Use Cases
- Internal developers needing an OpenAI-format API to access models deployed in Azure AI Foundry without provider-specific SDKs
- Platform owners who want keys, auto-discovery, and operational visibility with minimal cost and complexity

## Key Decisions (Final)
- Runtime:
  - Custom HTTP service (e.g., FastAPI) using LiteLLM Python SDK for execution, streaming, normalization, and error mapping
- Hosting:
  - Azure Container Apps with external HTTPS ingress; autoscaling and low ops
- Auth and Keys:
  - MVP: Table Storage-backed key store; validate Bearer token per request (no rate limiting or quotas initially)
  - PoC: MASTER_KEY-only auth; all clients share the same credential; no per-user budgets/permissions; Admin UI not used
- Secrets:
  - Store only essential provider credentials (e.g., Azure OpenAI/Foundry keys) in Azure Key Vault to control cost (PoC may use Container Apps secrets)
- Backend Surfaces:
  - Unified abstraction supports both Azure OpenAI deployments and Foundry serverless inference; default API version set to the latest (configurable later)
- Discovery:
  - Poll Foundry deployments; auto-register aliases; persist minimal metadata in Table Storage
- Streaming:
  - Emulate OpenAI streaming behavior exactly as expected by OpenAI clients; rely on LiteLLM stream support
- Telemetry:
  - Azure Monitor as primary sink; Application Insights optional, not required for MVP
- Logging Policy:
  - No prompt/response content; metadata-only logs with 90-day retention
- Model Naming:
  - Use Foundry shortnames (e.g., gpt-5, o3-mini, gpt-4.1-nano). Optional prefixes (chat_, embed_) for internal capability hints; strip for client-facing names if needed
- CI/CD:
  - Terraform for infrastructure; pipelines outside GitHub

## Architecture Overview
- Ingress: Azure Container Apps external HTTPS
- Gateway Service:
  - Validates client API key via Table Storage (MVP)
  - Resolves model alias to Azure OpenAI deployment or Foundry serverless endpoint
  - Invokes LiteLLM SDK (completion with stream support), forwards normalized responses and streaming chunks to clients
- Discovery Poller:
  - Periodically lists Foundry deployments
  - Updates a model catalog (Table Storage) with alias, backend surface, endpoint, last seen, and capability hints
- Persistence:
  - Table Storage for client keys and model catalog
  - Key Vault for provider secrets
- Observability:
  - Metrics and logs to Azure Monitor (custom events for tokens, latency, errors)

## Functional Requirements
- OpenAI-Compatible API
  - POST /v1/chat/completions
    - Inputs: messages, temperature, top_p, max_tokens, stop, stream
    - Behavior: Stream responses consistent with OpenAI client expectations; rely on LiteLLM normalization and error mapping
  - GET /v1/models
    - Return discovered aliases with minimal metadata
- Discovery
  - Poll Foundry project deployments; auto-expose newly discovered models
- Routing
  - Map aliases to backend surfaces; parameter mapping handled by LiteLLM wherever possible
- Auth
  - MVP: Bearer token validation against Table Storage (no throttling or quotas)
  - PoC: MASTER_KEY-only validation

## Non-Functional Requirements
- Performance: First token target under ~2–3 seconds; stable streaming under expected loads (1–100 users)
- Reliability: Autoscaling; graceful error handling; resilient discovery polling
- Security: Least-privilege access; provider keys in Key Vault; no sensitive payload logging
- Compliance: EU data residency; 90-day metadata retention; no PII processing due to content logging disabled
- Maintainability: Terraform-managed infrastructure; configurable region and API versions

## Data and Security
- Client Keys: Hashed and stored in Table Storage; simple status and timestamps
- Provider Secrets: Stored in Key Vault; retrieved at runtime via managed identity or secure access
- Logs: Only operational metadata; no prompt/response content

## Telemetry and Usage
- Azure Monitor Custom Metrics: Requests, errors, latency percentiles; token usage per request when available
- Dashboards and Alerts: For error rates and latency

## Model Discovery and Catalog
- Polling Interval: Configurable (e.g., 1–5 minutes)
- Catalog Fields (Table Storage): alias, backend surface, endpoint URL, visibility, capability hint, supports_streaming (heuristic), last_seen
- Auto-Exposure: Newly discovered models immediately available unless disabled

## API Design (MVP)
- POST /v1/chat/completions
  - Request: OpenAI-compatible fields; stream flag
  - Response: OpenAI-compatible completion or streaming chunks
- GET /v1/models
  - Response: List of aliases with minimal metadata
- Error Handling: OpenAI-style error shapes via LiteLLM’s exception mapping

## Deployment and CI/CD
- Terraform Modules: Container Apps environment and service; Table Storage; Key Vault; Azure Monitor
- Pipeline: Build service image, apply Terraform with region and secrets parameters

## Roadmap
- 0–6 Weeks (MVP)
  - v0.1: Core gateway, Table Storage key validation, Azure Monitor metrics, Container Apps deployment
  - v0.2: Streaming support; dual-surface routing; improved error mapping
  - v0.3: Discovery poller and /v1/models; alias rules and metadata catalog
- 6–12 Weeks
  - v0.4: /v1/embeddings; expanded catalog hints
  - v0.5: Terraform hardening, health checks, retry policies; optional private networking
  - v0.6: Operational dashboards; optional Application Insights

## Risks and Mitigations
- Discovery variability: Use naming conventions and manual overrides
- Streaming compatibility: Validate with OpenAI clients; tune framing/timeouts
- Secret cost: Store essential backend secrets in Key Vault; client keys in Table Storage
- API version drift: Default to latest; make configurable; monitor provider updates

## Open Questions
- Exact Foundry deployments listing endpoint and auth details
- Native streaming support on initial Foundry models; fallback policy
- Final polling interval and retry strategy
- Whether to add Application Insights later for deeper tracing
