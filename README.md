# AzureLIT

An OpenAI-compatible LLM gateway powered by [LiteLLM](https://github.com/BerriAI/litellm), running on Azure Container Apps. Unifies Azure OpenAI and Azure AI Foundry serverless endpoints behind a single, standardized API.

## Overview

AzureLIT provides a lightweight, cost-conscious HTTP gateway that exposes Azure OpenAI and Azure AI Foundry models through an OpenAI-compatible interface. It supports streaming chat completions, automatic model discovery, and minimal operational overhead.

**Current State:** Proof-of-Concept (PoC) with LiteLLM Proxy

## Features

- **OpenAI-Compatible API**: Drop-in replacement for OpenAI SDK clients
  - `POST /v1/chat/completions` with streaming support
  - `GET /v1/models` for model discovery
- **Multi-Provider Support**: Route to Azure OpenAI and Azure AI Foundry models
- **Authentication**: MASTER_KEY-only authentication (PoC); per-user virtual keys planned for MVP
- **Infrastructure as Code**: Fully automated deployment via Terraform
- **Observability**: Azure Monitor integration with metadata-only logging (no prompt/response content)

## Quick Start

### Prerequisites

- Azure subscription
- Terraform >= 1.0
- Azure CLI (for authentication)

### Configuration

1. Copy the example environment file and configure your secrets:

```bash
cd infra
cp example.env .env
```

2. Edit `.env` with your values:

```bash
# Required - Your Azure subscription ID
TF_VAR_subscription_id=your-subscription-id

# Required - Master key for client authentication (must start with 'sk-')
TF_VAR_litellm_master_key=sk-your-secure-master-key

# Azure AI Foundry credentials (for gpt-oss-120b model)
TF_VAR_foundry_project=your-project-name
TF_VAR_foundry_api_key=your-foundry-api-key
TF_VAR_foundry_api_version=2024-05-01-preview

# Optional - Override defaults
TF_VAR_location=swedencentral
TF_VAR_resource_group_name=AzureLIT-POC
```

### Deploy

```bash
cd infra
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

After deployment, Terraform outputs the container app URL:

```
container_app_fqdn = "azurelit-poc-container-app.<region>.azurecontainerapps.io"
container_app_url  = "https://azurelit-poc-container-app.<region>.azurecontainerapps.io"
```

### Test the Deployment

```bash
# Set your deployed URL and master key
ENDPOINT="https://<your-container-app-fqdn>"
MASTER_KEY="sk-your-master-key"

# Test chat completion
curl -sS \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4.1",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": false
  }' \
  "$ENDPOINT/v1/chat/completions"

# Test with streaming
curl -sS \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4.1",
    "messages": [{"role": "user", "content": "Count to 5"}],
    "stream": true
  }' \
  "$ENDPOINT/v1/chat/completions"

# List available models
curl -sS \
  -H "Authorization: Bearer $MASTER_KEY" \
  "$ENDPOINT/v1/models"
```

### Using with OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    api_key="sk-your-master-key",
    base_url="https://<your-container-app-fqdn>"
)

response = client.chat.completions.create(
    model="gpt-4.1",
    messages=[{"role": "user", "content": "Hello!"}],
    stream=False
)

print(response.choices[0].message.content)
```

## Project Structure

```
.
├── infra/                    # Terraform infrastructure
│   ├── main.tf              # Core resources (RG, Storage, Key Vault, Container Apps)
│   ├── openai.tf            # Azure OpenAI Cognitive Account + gpt-4.1 deployment
│   ├── kv.tf                # Key Vault secrets
│   ├── config.yaml          # LiteLLM Proxy configuration
│   ├── outputs.tf           # Deployment outputs (FQDN, URL)
│   ├── example.env          # Example environment variables
│   └── .env                 # Your secrets (gitignored)
├── docs/                     # Design and operational documentation
│   ├── PRD.md               # Product Requirements Document (MVP scope)
│   ├── POC.md               # Proof-of-Concept approach (current)
│   ├── DEPLOYMENT_SUMMARY.md
│   ├── MASTER_KEY_MANAGEMENT.md
│   ├── CUSTOM_AUTH.md
│   └── LINKS.md             # External references
└── AGENTS.md                 # Agent-specific project context
```

## Architecture

```
┌─────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│   Client/SDK    │────▶│  Azure Container    │────▶│   Azure OpenAI      │
│  (OpenAI fmt)   │     │  Apps (LiteLLM)     │     │   (gpt-4.1)         │
└─────────────────┘     └─────────────────────┘     └─────────────────────┘
                               │
                               └────────────────────▶┌─────────────────────┐
                                                     │  Azure AI Foundry   │
                                                     │  (gpt-oss-120b)     │
                                                     └─────────────────────┘
```

### Components

- **Azure Container Apps**: Hosts LiteLLM Proxy with external HTTPS ingress
- **Azure OpenAI**: Cognitive Services account with gpt-4.1 deployment
- **Azure AI Foundry**: Hub and Project for serverless model inference
- **Key Vault**: Secure storage for provider API keys
- **Log Analytics**: Metadata-only logging (no prompt/response content)

### Default Models

| Model | Provider | Identifier |
|-------|----------|------------|
| gpt-4.1 | Azure OpenAI | `azure/gpt-4.1` |
| gpt-oss-120b | Azure AI Foundry | `azure_ai/gpt-oss-120b` |

## Authentication

The PoC uses **MASTER_KEY-only authentication**:

- Set `TF_VAR_litellm_master_key` with a value starting with `sk-`
- All clients must include `Authorization: Bearer <MASTER_KEY>` header
- No per-user keys, budgets, or Admin UI in PoC (planned for MVP)

See [docs/MASTER_KEY_MANAGEMENT.md](docs/MASTER_KEY_MANAGEMENT.md) for details.

## Roadmap

- **PoC (Current)**: LiteLLM Proxy on Container Apps, MASTER_KEY auth, static model list
- **MVP v0.1**: Custom FastAPI gateway, Table Storage key validation, Azure Monitor
- **MVP v0.2**: Streaming support, dual-surface routing
- **MVP v0.3**: Model discovery poller, `/v1/models` endpoint
- **v0.4+**: Embeddings, expanded catalog, Terraform hardening

See [docs/PRD.md](docs/PRD.md) for full MVP scope.

## Security Notes

- **Secrets**: Never commit `.env` or `*.tfvars` files (both are gitignored)
- **Logging**: No prompt/response content is logged; only metadata (timestamps, latency, token counts)
- **HTTPS Only**: Container Apps enforces TLS on external ingress
- **Least Privilege**: Managed identities used where possible

## Documentation

- [PRD](docs/PRD.md) - Product Requirements Document
- [POC](docs/POC.md) - Proof-of-Concept deployment guide
- [DEPLOYMENT_SUMMARY](docs/DEPLOYMENT_SUMMARY.md) - Operational summary
- [MASTER_KEY_MANAGEMENT](docs/MASTER_KEY_MANAGEMENT.md) - Authentication details
- [CUSTOM_AUTH](docs/CUSTOM_AUTH.md) - Future custom auth implementation
- [LINKS](docs/LINKS.md) - External references

## License

TBD
