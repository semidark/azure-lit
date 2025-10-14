### Deployment Summary (PoC Authentication Updated)

This Terraform plan deploys a Proof-of-Concept (PoC) for the AzureLIT OpenAI-compatible gateway. The deployment creates the following resources in **Sweden Central** within the **AzureLIT-POC** resource group:

1.  **Azure Container App** running the LiteLLM proxy with external HTTPS ingress.
2.  **Azure AI Foundry Hub and Project** for model management.
3.  **Azure Key Vault** to store secrets (PoC level, optional; Container Apps secrets used preferentially to reduce cost).
4.  **Azure Storage Account** used by AI Foundry Hub.
5.  **Log Analytics Workspace** for observability.

#### Config Injection Approach (ACA)

We use an init container and an EmptyDir volume to inject `config.yaml` reliably:

- A `secret` named `config-yaml` stores the contents of configuration file.
- An `init_container` (`busybox`) writes the secret value to `/mnt/config/config.yaml`.
- An `EmptyDir` `volume` named `config-volume` is mounted to both the init container and the main LiteLLM container.
- The main container runs with args `--config /app/config.yaml` and mounts `/app` to the same `config-volume`, making the config available at runtime.

#### Authentication Model (PoC)

- Configure a single MASTER_KEY via `LITELLM_MASTER_KEY` (Container Apps secret) or `general_settings.master_key` in `config.yaml`.
- With a MASTER_KEY set, LiteLLM enforces client authentication automatically: clients must include the master key in the Authorization header.
- No database is used, so all clients share the same credential (the MASTER_KEY). Per-user budgets, permissions, and the Admin UI for key management are not available in the PoC.

Client requirement:
```
Authorization: Bearer <LITELLM_MASTER_KEY>
```

#### Additional Hardening

- `litellm_settings.drop_params: true` prevents clients from overriding provider credentials.
- `forward_client_headers_to_llm_api: false` avoids passing client headers upstream.
- DB-related features disabled to keep the PoC DB-less.

### Mermaid Diagram

```mermaid
graph TD
    subgraph "AzureLIT-POC Resource Group"
        subgraph "Azure Container App Environment"
            A[Container App: litellm-proxy]
            A --> B{{Init Container: writes config.yaml}}
            A --> C[(EmptyDir Volume: config-volume)]
        end

        subgraph "Azure AI Foundry"
            D[AI Foundry Hub] --> E[AI Foundry Project]
        end

        subgraph "Supporting Services"
            F[Key Vault (optional)]
            G[Storage Account] --> D
            H[Log Analytics Workspace] --> A
        end
    end

    I[Client with Bearer MASTER_KEY] -->|HTTPS /v1/*| A
```

### Notes

- If no MASTER_KEY is set, the proxy is unauthenticated; use only for local development.
- For production with multiple clients, plan Virtual Keys + database or a custom key store.
