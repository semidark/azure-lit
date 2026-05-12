# Implementation Plan: LiteLLM-Native SearXNG Search

**Status:** Ready for implementation  
**Target:** Add SearXNG as a JSON-only metasearch backend behind LiteLLM's native `/search` endpoint  
**Auth model:** Unified — same `Authorization: Bearer <key>` as LiteLLM (via existing `custom_auth.py`)  
**Cost impact:** Minimal — SearXNG runs as a second container in the existing single Container App

---

## 1. Goals

1. Colleagues can query `POST /v1/search/searxng-search` on the existing LiteLLM endpoint with their existing API key.
2. No new infrastructure (same Container App, same Container App Environment, same Resource Group).
3. No custom image builds — official pinned images only.
4. Search results from engines that actually work from Azure datacenter IPs (no Google/Startpage/Bing CAPTCHA hell).
5. Documented, reproducible, Terraform-managed from day one.

---

## 2. Architecture

### 2.1 Container Layout

The existing `litellm-proxy` Container App becomes a **2-container pod**:

| Container | Image (pinned) | Port | Exposed to Internet? | Purpose |
|---|---|---|---|---|
| `litellm` | `ghcr.io/berriai/litellm:main-v1.83.14-stable.patch.3` | `4000` | ✅ Yes (ingress target) | Unchanged — proxies all external traffic |
| `searxng` | `docker.io/searxng/searxng@sha256:e29964c6e23ce4bb09a173c5d7618534a40497d585ae9d90ed1bd93bab9474a9` | `8080` | ❌ No (internal only) | JSON-only metasearch backend |

**Ingress:** Stays on port `4000`. No nginx, no Traefik, no reverse proxy needed.

### 2.2 Request Flow

```
Client (colleague's agent)
  │
  │ POST /v1/search/searxng-search
  │ Authorization: Bearer sk-abc123
  │
  ▼
Azure Container Apps Ingress (port 4000, HTTPS)
  │
  ▼
LiteLLM Container (port 4000)
  │
  ├─ custom_auth.py validates Bearer token against API_KEYS env var
  │
  ├─ LiteLLM routes /v1/search/* to its built-in search handler
  │
  ├─ search_tools config resolves "searxng-search" → localhost:8080
  │
  │  GET http://localhost:8080/search?q=<query>&format=json
  │
  ▼
SearXNG Container (port 8080, internal only)
  │
  ├─ Receives query from LiteLLM (same pod network)
  │
  ├─ Queries curated engine list (Brave, Mojeek, Mwmbl, etc.)
  │
  ├─ Aggregates JSON results
  │
  │  {"results": [{"title": "...", "url": "...", "snippet": "..."}]}
  │
  ▼
LiteLLM reformats to Perplexity-compatible response
  │
  ▼
Client receives standardized search response
```

### 2.3 Why This Architecture?

| Alternative Considered | Why Rejected |
|---|---|
| **Separate Container App for SearXNG** | Doubles infra cost (second app = second charge), separate lifecycle, more Terraform |
| **nginx reverse proxy** | Adds a 3rd container, config complexity, no benefit since LiteLLM already handles routing |
| **Traefik + plugin** | Requires custom image build (plugin pre-compilation), file-based config instead of labels, auth header mismatch |
| **Public SearXNG instance** | Violates privacy goals, rate-limited by third parties, no unified auth |
| **Direct SearXNG with its own auth** | Colleagues would need two different API keys and two different auth headers |

**Key insight:** LiteLLM natively supports SearXNG as a `search_provider` since v1.78.7. We just need to add a `search_tools:` stanza to `config.yaml` and run SearXNG on `localhost:8080`.

---

## 3. File Changes

### 3.1 New Files

#### `infra/searxng-settings.yml.tpl`

Terraform template rendering SearXNG's `settings.yml`. Uses explicit opt-in engine model (not `use_default_settings: true`) to avoid accidentally enabling Google/Bing if upstream defaults change.

```yaml
# AzureLIT SearXNG Configuration
# Rendered by Terraform; do not edit manually.
#
# DESIGN DECISIONS:
# - JSON-only mode (no HTML): designed for API consumption by AI agents
# - Bot detection disabled: server.limiter=false; all requests come from
#   LiteLLM inside the same pod, so bot detection would falsely block us.
# - Favicon fetching disabled: saves bandwidth and CPU for headless API usage
# - Static dummy secret_key: not used for sessions in JSON-only mode;
#   SearXNG requires the key to exist but we don't use cookie-based sessions.
# - Explicit engine whitelist: only engines known to work from Azure
#   datacenter IPs; Google/Startpage/Bing/Yandex are blacklisted due to
#   aggressive CAPTCHA blocking of cloud IP ranges.

general:
  debug: false
  instance_name: "AzureLIT-SearXNG"

search:
  favicon_resolver: ""
  formats:
    - json

server:
  bind_address: "0.0.0.0"
  port: 8080
  limiter: false
  public_instance: false
  secret_key: "azure-lit-dummy-not-used-for-sessions"

# ---------------------------------------------------------------------------
# ENGINE CURATION
# ---------------------------------------------------------------------------
# Strategy: explicit opt-in. Do NOT use use_default_settings:true which
# auto-enables ~125 engines including Google/Bing.
#
# 🔴 BLOCKED (aggressive CAPTCHA from Azure/cloud IPs):
#   google, startpage, bing, yandex
#
# 🟢 ENABLED (own index or API-based, cloud-friendly):
#   brave, mojeek, mwmbl, wiby, yep
#
# 🟡 FALLBACK (moderate block risk, monitor):
#   duckduckgo
#
# 🔵 SUB-ENGINES (reliable but narrow scope):
#   qwant news/images/videos, wikipedia, wikidata,
#   arxiv, github, stackoverflow, pypi, docker hub
# ---------------------------------------------------------------------------

engines:
  # -- PRIMARY GENERAL-WEB (own index, cloud-safe) --
  - name: brave
    disabled: false
  - name: mojeek
    disabled: false
  - name: mwmbl
    disabled: false
  - name: wiby
    disabled: false
  - name: yep
    disabled: false

  # -- FALLBACK --
  - name: duckduckgo
    disabled: false

  # -- QWANT SUB-ENGINES (EU-friendly; main qwant web disabled upstream) --
  - name: qwant news
    disabled: false
  - name: qwant images
    disabled: false
  - name: qwant videos
    disabled: false

  # -- KNOWLEDGE / DEVELOPER (API-based, never blocks) --
  - name: wikipedia
    disabled: false
  - name: wikidata
    disabled: false
  - name: arxiv
    disabled: false
  - name: github
    disabled: false
  - name: stackoverflow
    disabled: false
  - name: pypi
    disabled: false
  - name: docker hub
    disabled: false

  # -- EXPLICITLY DISABLED (high CAPTCHA risk from cloud IPs) --
  - name: google
    disabled: true
  - name: google images
    disabled: true
  - name: google news
    disabled: true
  - name: google videos
    disabled: true
  - name: google scholar
    disabled: true
  - name: startpage
    disabled: true
  - name: startpage news
    disabled: true
  - name: startpage images
    disabled: true
  - name: bing
    disabled: true
  - name: bing images
    disabled: true
  - name: bing news
    disabled: true
  - name: bing videos
    disabled: true
  - name: yandex
    disabled: true
  - name: yandex images
    disabled: true
```

**Key design notes:**
- `server.limiter: false` is intentional. All traffic to SearXNG originates from LiteLLM inside the same pod (`localhost`). Bot detection would misclassify automated API requests as bot traffic and block them.
- `secret_key` is a static dummy string. SearXNG requires this key to exist at startup, but we don't use HTML rendering, cookies, or sessions. Since SearXNG is unreachable from the internet, session forgery is not a threat.
- Engine list is conservative. We can expand later after validating each engine from the live deployment.

#### `docs/SEARCH_SETUP.md` (new)

Operational documentation for colleagues. Includes:
- How to call the search endpoint (`curl` example)
- Python example with `openai` SDK or `httpx`
- Supported parameters (`query`, `max_results`, `search_domain_filter`, etc.)
- Engine availability explanation ("Why no Google results?")
- Troubleshooting:
  - Empty results → check SearXNG logs for engine timeouts
  - `403 Forbidden` → invalid API key (same auth as chat completions)
  - `502 Bad Gateway` → SearXNG container crashed, ACA will auto-restart

### 3.2 Modified Files

#### `infra/config.yaml.tpl`

Add `search_tools:` as a **top-level key**, sibling to `model_list:` and `general_settings:`.

```yaml
model_list:
  # ... existing model entries ...

# ---------------------------------------------------------------------------
# SEARCH TOOLS
# ---------------------------------------------------------------------------
# SearXNG instance runs as a sidecar container on localhost:8080.
# Auth is handled by LiteLLM's custom_auth.py; SearXNG itself has no auth.
# ---------------------------------------------------------------------------
search_tools:
  - search_tool_name: searxng-search
    litellm_params:
      search_provider: searxng
      api_base: http://localhost:8080

litellm_settings:
  # ... existing settings ...
```

**Placement rule:** `search_tools` must be at the root level of `config.yaml`, NOT nested inside `model_list`, `general_settings`, or `litellm_settings`. LiteLLM validates this at startup.

#### `infra/main.tf`

##### 3.2.1 New locals

```hcl
locals {
  # ... existing locals ...

  searxng_settings = templatefile("${path.module}/searxng-settings.yml.tpl", {})
}
```

##### 3.2.2 New secret

```hcl
# In azurerm_container_app.ca.secret block, add:
secret {
  name  = "searxng-settings"
  value = local.searxng_settings
}
```

##### 3.2.3 New container block

Add inside `template { container { ... } }` (as a second container, not replacing LiteLLM):

```hcl
container {
  name   = "searxng"
  image  = "docker.io/searxng/searxng@sha256:e29964c6e23ce4bb09a173c5d7618534a40497d585ae9d90ed1bd93bab9474a9"
  cpu    = 0.25
  memory = "0.25Gi"

  # SearXNG image ENTRYPOINT is /usr/local/searxng/entrypoint.sh
  # but it has no CMD. If we override 'command' we must chain back
  # to the entrypoint after copying our custom settings.yml.
  command = ["/bin/sh", "-c"]
  args    = ["cp /mnt/secrets/searxng-settings /etc/searxng/settings.yml && exec /usr/local/searxng/entrypoint.sh"]

  # No env vars needed — all config is in settings.yml

  volume_mounts {
    name = "secrets-volume"
    path = "/mnt/secrets"
  }
}
```

##### 3.2.4 Force revision on settings change

Add to the existing LiteLLM container's env block:

```hcl
env {
  name  = "SEARXNG_SETTINGS_SHA"
  value = sha256(local.searxng_settings)
}
```

This ensures any change to `searxng-settings.yml.tpl` triggers a new Container App revision, same pattern used for `LITELLM_CONFIG_SHA` and `CUSTOM_AUTH_SHA`.

##### 3.2.5 Resource allocation summary

| Container | CPU | Memory |
|---|---|---|
| `litellm` | 0.50 | 1.00 Gi |
| `searxng` | 0.25 | 0.25 Gi |
| **Total** | **0.75** | **1.25 Gi** |

ACA Consumption plan limits: **2 vCPU / 4 Gi per app**. We are well within limits.

**No health probe on SearXNG** (MVP decision). If SearXNG crashes, ACA auto-restarts the pod. LiteLLM search calls receive `502` until recovery. We add probes later if stability becomes an issue.

#### `infra/outputs.tf`

Add:

```hcl
output "search_api_url" {
  description = "LiteLLM search endpoint URL"
  value       = "https://${azurerm_container_app.ca.ingress[0].fqdn}/v1/search/searxng-search"
}
```

#### `AGENTS.md`

Add a new **Search** section covering:
- Endpoint: `POST /v1/search/searxng-search`
- Auth: same `Authorization: Bearer <key>` header as chat completions
- No new API keys or variables needed
- Engine curation: explains why Google/Bing results are absent
- Cost: SearXNG is free/open-source; only Azure Container Apps compute cost
- Architecture note: SearXNG runs as internal sidecar, not exposed to internet

#### `ARCHITECTURE.md`

Add a **Search / SearXNG** subsection to the Architecture heading:
- SearXNG as a sidecar container in the same pod
- LiteLLM's native `search_tools` integration
- Curated engine list for cloud IP compatibility
- Traffic flow diagram (same as section 2.2 above)

---

## 4. Terraform Execution

No new variables. `var.api_keys` is automatically reused for search auth.

```bash
cd infra
terraform plan -out=tfplan
terraform apply tfplan
```

The plan will show:
- 1 new secret (`searxng-settings`)
- 1 new container in the existing Container App (`searxng`)
- 1 modified env var (`SEARXNG_SETTINGS_SHA` added to LiteLLM container)
- 1 new output (`search_api_url`)

---

## 5. Testing Plan

### 5.1 Post-Deploy Verification

Run these commands after `terraform apply` completes:

```bash
# Set from Terraform outputs
FQDN=$(terraform output -raw container_app_fqdn)
URL=$(terraform output -raw container_app_url)
SEARCH_URL=$(terraform output -raw search_api_url)
API_KEY="sk-your-test-key"  # one of the keys from TF_VAR_api_keys

# 1. Health check (no auth required)
echo "=== 1. LiteLLM Health ==="
curl -s "${URL}/health/liveliness" | jq .

# 2. Chat completions still work (regression test)
echo "=== 2. Chat Completions ==="
curl -s "${URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4.1","messages":[{"role":"user","content":"hello"}]}' | jq '.choices[0].message.content'

# 3. Search endpoint (the new feature)
echo "=== 3. Search ==="
curl -s "${SEARCH_URL}" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"query":"latest AI developments","max_results":5}' | jq '.results[:2]'

# 4. Invalid key should be rejected
echo "=== 4. Auth Rejection ==="
curl -s -o /dev/null -w "%{http_code}" "${SEARCH_URL}" \
  -H "Authorization: Bearer sk-invalid" \
  -H "Content-Type: application/json" \
  -d '{"query":"test"}'
# Expected: 401

# 5. Direct SearXNG API (from inside pod - for debugging)
# This requires Azure Container Apps console/exec access:
# az containerapp exec --name litellm-proxy --resource-group AzureLIT-POC
# Then inside the pod:
# curl -s "http://localhost:8080/search?q=hello&format=json" | jq '.results | length'
```

### 5.2 Expected Response Format

LiteLLM reformats SearXNG JSON into Perplexity-compatible response:

```json
{
  "object": "search",
  "results": [
    {
      "title": "Latest Advances in Artificial Intelligence",
      "url": "https://example.com/article",
      "snippet": "This article discusses recent developments...",
      "date": "2024-01-15"
    }
  ]
}
```

If SearXNG returns empty results (all engines timed out or blocked), LiteLLM passes through an empty `results: []` array with HTTP 200.

---

## 6. Engine Reliability Notes

### 6.1 Why We Blocked Google/Bing/Startpage/Yandex

From SearXNG community reports and our own research:

| Engine | Block Behavior from Azure IPs |
|---|---|
| Google | reCAPTCHA / "unusual traffic" ~100% of the time from cloud datacenters |
| Startpage | Proxies Google; inherits all blocks plus its own datacenter blacklist |
| Bing | Already disabled upstream; Microsoft aggressively CAPTCHAs Azure IP ranges |
| Yandex | Geo-blocks EU/US cloud IPs; returns empty results or HTTP 403 |

### 6.2 Why Our Curated List Works

| Engine | Index Type | Cloud IP Tolerance |
|---|---|---|
| Brave | Own independent index | High — no Google/Bing dependency |
| Mojeek | Own independent UK index | High — built for privacy aggregators |
| Mwmbl | API-oriented tiny index | Very high — designed for programmatic access |
| Wiby | Small independent index | Very high |
| Yep | Independent (Ahrefs) | High |
| DuckDuckGo | Bing proxy + own | Moderate — sometimes rate-limits but usually works |
| Qwant subs | Own EU index | High for news/images/videos |
| Wikipedia/Wikidata/arxiv/GitHub/etc. | API-based | Never blocks |

### 6.3 Result Quality Expectations

**Without Google/Bing, search results will feel different.**

- **Brave** is quite good for general web; independent index with decent coverage.
- **Mojeek** has a smaller index but is completely independent.
- **DuckDuckGo** fills gaps when it works.
- For technical/developer queries, **GitHub + Stack Overflow + arXiv** are excellent.
- For encyclopedic queries, **Wikipedia + Wikidata** are perfect.

**Recommendation:** Monitor colleague feedback. If general web search feels thin, we can add more engines one-by-one after testing from the live deployment. Do NOT add Google/Startpage/Bing — the CAPTCHA problem is structural, not fixable without residential proxies.

---

## 7. Security Considerations

| Concern | Mitigation |
|---|---|
| SearXNG exposed without auth | Not reachable from internet (port 8080 not in ingress). Only LiteLLM inside same pod can access it. |
| SearXNG `secret_key` is static | Intentional. No sessions/cookies used in JSON-only mode. Documented in `searxng-settings.yml.tpl`. |
| Bot detection disabled | Intentional. Traffic is intra-pod from LiteLLM, not public internet. Bot detection would block legitimate API usage. |
| SearXNG makes outbound HTTP to search engines | Required by design. ACA default allows all outbound. No sensitive data is sent — just search queries. |
| Shared API keys for chat + search | By design. Colleagues use one key for both. If key compromise is suspected, rotate via `terraform apply` with new `TF_VAR_api_keys`. |

---

## 8. Rollback Plan

If something goes wrong, remove the SearXNG container and revert `config.yaml.tpl`:

```bash
# Option 1: revert the Terraform commit and re-apply
git revert <commit>
cd infra && terraform apply

# Option 2: manual emergency removal (edit main.tf to remove searxng container block
# and the search_tools stanza from config.yaml.tpl, then terraform apply)
```

LiteLLM chat completions are unaffected by SearXNG failures — they are independent code paths. The only impact is the `/v1/search/*` endpoint returning errors.

---

## 9. Future Enhancements (Out of Scope for MVP)

| Feature | Effort | Value |
|---|---|---|
| Add Redis cache for SearXNG | Medium | Faster repeat queries, reduces engine load |
| Per-key search rate limiting | Medium | Prevent search abuse without chat impact |
| Engine health monitoring / auto-disable | Medium | If Brave goes down, auto-fallback to others |
| Residential proxy for Google/Bing | High | Would restore Google quality but adds $$$ and complexity |
| Search result caching in Log Analytics | Low | Log searches for usage analysis |

---

## 10. Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-05-12 | Use LiteLLM native `/search` instead of nginx/Traefik proxy | Simpler, no custom images, unified auth, fewer containers |
| 2026-05-12 | SearXNG as sidecar in same Container App | Cheapest; same lifecycle; localhost networking |
| 2026-05-12 | Explicit engine opt-in (not `use_default_settings:true`) | Prevents surprise CAPTCHA engines if upstream defaults change |
| 2026-05-12 | Disable bot detection (`limiter: false`) | All traffic is intra-pod from LiteLLM; bot detection would block us |
| 2026-05-12 | Static dummy `secret_key` | Not used for sessions in JSON-only mode; simplifies config |
| 2026-05-12 | No health probe on SearXNG (MVP) | ACA auto-restart on failure is sufficient; add probe later if needed |
| 2026-05-12 | No new Terraform variables | Reuses existing `var.api_keys` for auth |
