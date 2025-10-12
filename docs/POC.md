Certainly! Here’s your PRD reformatted for clarity and readability, with all your original content intact.

---

# PoC Objectives

- **Run the default LiteLLM Proxy container on Azure with external HTTPS ingress.**
- **Preconfigure one or more Azure OpenAI chat deployments in a config file at deploy time.**
- **Support OpenAI-compatible `/v1/chat/completions` including streaming with OpenAI-style chunks.**
- **Use a single master key for access** (no virtual keys, no database).
- **No model discovery or dynamic updates;** changes are applied via Terraform redeploy.
- **Keep the footprint minimal:** no APIM, no Table Storage, no DB. Region default: Sweden Central.


# Why This Approach Works

- **LiteLLM Proxy** exposes OpenAI-compatible endpoints, supports Azure provider settings via env vars, and can be launched with config.yaml or CLI/Docker without custom code [1]. It returns OpenAI-format responses for non-streaming and streaming, mapping provider errors to OpenAI exceptions [1].
- **Streaming Support:** LiteLLM supports streaming via `stream=True`, emitting OpenAI-style streaming chunks (`chat.completion.chunk`) expected by client SDKs [1].
- **Azure Container Apps** is a low-ops, serverless container platform ideal for a simple gateway. **Terraform** is a supported IaC option for Azure [3].


# High-Level Architecture

- **Azure Container Apps** (external ingress) runs the official LiteLLM image.
- **Config.yaml** (mounted or passed at runtime) lists Azure OpenAI chat deployments.
- **Environment variables** provide Azure credentials and API version to the container.
- **Optional:** Store secrets in Container Apps “secrets” (built-in) to avoid Key Vault cost for the PoC. Add Key Vault later if needed.
- **Logging:** Logs go to Container Apps/Log Analytics; no prompt/response content is logged.


# Azure Resources (Minimal)

- **Resource Group** (Sweden Central)
- **Log Analytics Workspace** (required by Container Apps environment)
- **Container Apps Environment** (external ingress)
- **Container App:**
  - Image: `ghcr.io/berriai/litellm:main-latest`
  - Port: `4000`
  - External ingress enabled
  - Env vars: `AZURE_API_BASE`, `AZURE_API_KEY`, `AZURE_API_VERSION`, plus any optional settings
  - Config volume/secret for `config.yaml`
- **Optional Later:** Key Vault for provider secrets (for PoC use Container Apps secrets to keep costs down).


# LiteLLM Configuration (Models)

- **Use a config file** with `model_list` entries. Example (values via env vars; no secrets in the file):

  ```yaml
  model_name: gpt-4o-mini
  litellm_params:
    model: azure/<your_azure_deployment_name>
    api_base: os.environ/AZURE_API_BASE
    api_key: os.environ/AZURE_API_KEY
    api_version: os.environ/AZURE_API_VERSION
  ```
- **List multiple deployments** in `model_list`; clients choose by model name. This is the standard way to configure the proxy via `config.yaml` and env vars [1].


# Streaming Behavior

- **Clients send `stream=true`;** the proxy returns OpenAI-format streaming chunks and terminates the stream with expected markers. LiteLLM docs show the streaming call pattern and chunk format for OpenAI-style streaming [1].
- **No additional streaming gateway is required;** simply pass through the proxy’s streaming responses to the client.


# Authentication for PoC

- **Default:** LiteLLM Proxy accepts any API key for OpenAI-compatible calls (the standard quick-start uses `api_key="anything"`) [1]. For a strict “master key” without database or custom code:
  - **Option A (simplest):** Rely on network restrictions (e.g., IP allowlist) and accept a dummy API key until you add an auth layer.
  - **Option B:** To enforce a single key now using only the default image, use Container Apps ingress controls or a simple upstream reverse proxy requiring a fixed Authorization header.
- **Future:** Add a real key store and auth hook once moving beyond PoC.


# Terraform Plan (Overview)

- **Create resource group** and variables (region default Sweden Central).
- **Create Log Analytics Workspace** and **Container Apps Environment**.
- **Define Container App:**
  - image = `ghcr.io/berriai/litellm:main-latest`
  - args = `["--config", "/app/config.yaml"]`
  - mount `config.yaml` from a Container Apps secret or volume
  - set environment variables:
    - `AZURE_API_BASE=https://<your-azure-openai-resource>.openai.azure.com/`
    - `AZURE_API_KEY` (Container Apps secret)
    - `AZURE_API_VERSION=<latest version you choose>`
  - ingress external, target port 4000, scale min=0 or 1 (PoC choice)
- **Outputs:** external URL of Container App for client use.
- **Redeploy** to update `model_list` or env vars.


# Deployment Steps

1. **Author `config.yaml`** with your Azure OpenAI deployments under `model_list` (chat-only for the PoC).
2. **Terraform apply** to provision:
   - RG, LA workspace, Container Apps env, Container App.
   - Push `config.yaml` into a Container Apps secret so the container can read `/app/config.yaml`.
   - Set env vars for `AZURE_API_BASE`, `AZURE_API_KEY`, `AZURE_API_VERSION`.
3. **Verify the app is up** by hitting the health path (root returns the proxy UI or 200 depending on image version) and then call `/v1/chat/completions` via a client.


# Client Usage (Example Flow)

- **Configure OpenAI SDK** to point `base_url` to your proxy and pass any API key (or “master key” if enforced). Example:
  ```python
  client = openai.OpenAI(api_key="anything", base_url="https://<your-container-app>")
  response = client.chat.completions.create(
      model="<your-model-name>",
      messages=[{"role":"user","content":"hello"}]
  )
  ```
- **For streaming:** set `stream=true` and iterate chunks. LiteLLM shows the expected req/resp shapes and streaming setup [1].
- **Confirm** model name matches `model_name` in `config.yaml`.


# Observability and Logging

- **Container Apps/Log Analytics** for stdout/stderr.
- **Disable request/response logging hooks** to ensure prompts/responses aren’t captured.
- **For deeper telemetry (later):** LiteLLM provides callbacks (e.g., cost, latency), and a `transform_request` utility for debugging normalization [1].


# Security Notes (PoC)

- **Use Container Apps secrets for `AZURE_API_KEY`;** avoid embedding secrets in the image or `config.yaml`.
- **Restrict external access** to known IPs or use a test environment with ephemeral exposure.
- **Plan to add** proper key validation or a gateway after PoC.


# Validation Checklist

- Non-stream request returns OpenAI-format completion (`choices[0].message.content`) [1].
- Streaming request returns `chat.completion.chunk` events and completes cleanly [1].
- Error mapping: misconfigure a key or model and confirm OpenAI-style exceptions surface to the client [1].
- Throughput: test a few concurrent users; verify stability and time-to-first-token.


# PoC Limitations (Intentional)

- No dynamic model discovery; updates require Terraform redeploy.
- No per-user keys, quotas, or rate limiting.
- Chat-completions only; embeddings/images etc. are out of scope.
- Minimal auth (single master key goal) and basic ingress protection.


# Next Steps After PoC

- Add a discovery poller and model catalog (Table Storage) for new deployments.
- Introduce LiteLLM callbacks for metrics (tokens/latency) to Azure Monitor/App Insights.
- Add a lightweight key store and per-key auth for multi-user scenarios.
- Expand to Azure AI Foundry serverless endpoints and embeddings.


# Key References

- LiteLLM Proxy quick start (config.yaml, Docker run, client base_url usage) and streaming response format in OpenAI shape [1].
- Azure Container Apps and Terraform are supported in Azure’s ecosystem; Container Apps is a good fit for serverless containers [3].

---
