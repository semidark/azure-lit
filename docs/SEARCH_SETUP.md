# Search Setup — SearXNG via LiteLLM

AzureLIT exposes a unified search endpoint backed by SearXNG, a privacy-respecting metasearch engine. Colleagues use the same API key as for chat completions — no separate credentials needed.

## Endpoint

```
POST https://<container-app-fqdn>/v1/search/searxng-search
```

Replace `<container-app-fqdn>` with the value from `terraform output container_app_fqdn`.

## Authentication

Same `Authorization: Bearer <key>` header as chat completions. The key must be one of the comma-separated keys in `TF_VAR_api_keys`.

```bash
curl -s "https://<fqdn>/v1/search/searxng-search" \
  -H "Authorization: Bearer sk-your-key" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "latest AI developments",
    "max_results": 5
  }'
```

## Python Example

```python
import httpx

url = "https://<fqdn>/v1/search/searxng-search"
headers = {
    "Authorization": "Bearer sk-your-key",
    "Content-Type": "application/json",
}
payload = {
    "query": "latest AI developments",
    "max_results": 5,
}

resp = httpx.post(url, headers=headers, json=payload)
resp.raise_for_status()
for item in resp.json()["results"]:
    print(f"{item['title']}\n  {item['url']}\n  {item.get('snippet', '')}\n")
```

## Request Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `query` | string | Yes | — | Search query string |
| `max_results` | integer | No | 10 | Maximum number of results to return |
| `search_domain_filter` | array | No | — | Restrict results to specific domains |

## Response Format

LiteLLM reformats SearXNG JSON into a Perplexity-compatible response:

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

## Why No Google/Bing Results?

Google, Bing, Startpage, and Yandex aggressively block requests from Azure datacenter IP ranges with CAPTCHAs. Because SearXNG is hosted in Azure, these engines are disabled. The curated engine list includes independent indexes (Brave, Mojeek, Mwmbl, Wiby, Yep) and API-based sources (Wikipedia, arXiv, GitHub) that tolerate cloud IPs.

**Result quality without Google/Bing:**
- **General web**: Brave and Mojeek provide good coverage.
- **Technical queries**: GitHub, Stack Overflow, arXiv, PyPI are excellent.
- **Encyclopedic**: Wikipedia and Wikidata are perfect.
- **Fallback**: DuckDuckGo fills gaps when it works.

If general web search feels thin, let us know — we can expand the engine list after testing from the live deployment.

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `401 Unauthorized` | Invalid or missing API key | Use a key from `TF_VAR_api_keys` |
| `502 Bad Gateway` | SearXNG container crashed | Wait 10–30s for ACA auto-restart; retry |
| Empty `results: []` | All engines timed out or returned no hits | Retry with a more specific query; check SearXNG logs |
| Slow response (>10s) | Engine timeout (e.g., DuckDuckGo rate-limiting) | Normal — SearXNG waits for engines before returning |

### Checking SearXNG Logs

```bash
az containerapp logs show \
  --name litellm-proxy \
  --resource-group AzureLIT-POC \
  --container searxng \
  --follow
```

### Direct SearXNG Access (Debugging)

From inside the pod (requires Azure Container Apps exec):

```bash
az containerapp exec --name litellm-proxy --resource-group AzureLIT-POC
# Inside the pod:
curl -s "http://localhost:8080/search?q=hello&format=json" | jq .
```

## Architecture

SearXNG runs as a second container (`searxng`) inside the same Azure Container App as LiteLLM. LiteLLM routes `/v1/search/searxng-search` to `localhost:8080` via its native `search_tools` integration. SearXNG is not exposed to the internet — only LiteLLM inside the pod can reach it.

For full architecture details, see `ARCHITECTURE.md`.

## Health & Monitoring

There is no explicit health probe on the SearXNG container in the MVP. Azure Container Apps auto-restarts the pod if the container exits. If search stability becomes an issue, we will add a startup/liveness probe later.
