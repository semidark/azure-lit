# Usage Analysis — API Key Tracking

This document describes the usage tracking feature for AzureLIT, which provides per-API-key usage analytics using Azure Log Analytics.

## Overview

AzureLIT tracks usage for every API request made through the proxy. Usage data is sent to Azure Log Analytics as a custom table and can be queried using KQL or the `scripts/usage-report.py` CLI tool.

### Key Features

- **Per-Key Tracking**: Each API key is hashed (SHA-256 prefix) for privacy
- **Token Counts**: Tracks `prompt_tokens`, `completion_tokens`, cached tokens, and non-cached tokens per request
- **Cache Visibility**: Separates cached vs. non-cached input tokens so cache hit rates can be measured
- **Cost Tracking**: Cost field is currently set to `0` pending accurate cached-token pricing validation (see [Cost Tracking Status](#cost-tracking-status))
- **Failure Logging**: Captures failed requests with error type classification
- **Flexible Queries**: Query by date range, specific key, or group by model using KQL

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Container Apps                          │
│  ┌──────────────┐    ┌──────────────────┐                      │
│  │ LiteLLM      │───▶│ usage_callback.py │──▶ Log Analytics    │
│  │ Proxy        │    │ (success/failure) │    (Custom Table)   │
│  └──────────────┘    └──────────────────┘                      │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. Client makes request with `Authorization: Bearer <api_key>`
2. LiteLLM processes the request
3. `usage_callback.py` receives success/failure event
4. Callback sends data to Log Analytics custom table (`LiteLLMUsage_CL`)
5. Query with KQL or CLI tool

## Log Analytics Schema

**Table Name**: `LiteLLMUsage_CL` (custom log table)

Log Analytics appends type suffixes to custom field names automatically (e.g. `KeyHash` → `KeyHash_s`, `TokensIn` → `TokensIn_d`). Query using the suffixed names as shown below.

| Column | Type | Description |
|--------|------|-------------|
| `TimeGenerated` | datetime | Request timestamp |
| `KeyHash_s` | string | First 16 chars of SHA-256 hash of API key |
| `Model_s` | string | Model name (e.g., `gpt-4.1`) |
| `TokensIn_d` | real | Total prompt tokens (cached + non-cached) |
| `TokensOut_d` | real | Completion tokens generated |
| `CachedTokensIn_d` | real | Prompt tokens served from cache |
| `NonCachedTokensIn_d` | real | Prompt tokens not in cache (billed at full rate) |
| `CacheWriteTokensIn_d` | real | Prompt tokens written to cache (Anthropic-style; typically 0 for Azure/OpenAI) |
| `Cost_d` | real | Always `0` — suppressed until cached-token pricing is validated |
| `Status_s` | string | `success` or `failure` |
| `ErrorType_s` | string | (Only for failures) `AuthenticationError`, `RateLimit`, `Timeout`, `ValidationError`, or `Unknown` |

> **Note on legacy columns**: Earlier ingested rows may show duplicate columns with doubled suffixes such as `KeyHash_s_s`, `Model_s_s`, `Status_s_s`. These are schema artifacts from an earlier callback version and will not appear in rows ingested after the current callback was deployed. They can be ignored; the reporting script normalises both forms automatically.

## Querying Usage

### KQL Examples

**Daily summary (all keys)**:
```kusto
LiteLLMUsage_CL
| where TimeGenerated > ago(1d)
| summarize
    Requests = count(),
    Failures = countif(Status_s == "failure"),
    TokensIn = sum(TokensIn_d),
    TokensOut = sum(TokensOut_d),
    CachedTokensIn = sum(CachedTokensIn_d),
    NonCachedTokensIn = sum(NonCachedTokensIn_d)
    by KeyHash_s
| order by Requests desc
```

**Per-model breakdown**:
```kusto
LiteLLMUsage_CL
| where TimeGenerated > ago(7d)
| summarize
    Requests = count(),
    TokensIn = sum(TokensIn_d),
    TokensOut = sum(TokensOut_d),
    CachedTokensIn = sum(CachedTokensIn_d),
    NonCachedTokensIn = sum(NonCachedTokensIn_d)
    by Model_s
| order by Requests desc
```

**Cache hit rate by model**:
```kusto
LiteLLMUsage_CL
| where TimeGenerated > ago(7d)
| where Status_s == "success" and TokensIn_d > 0
| summarize
    TokensIn = sum(TokensIn_d),
    CachedTokensIn = sum(CachedTokensIn_d)
    by Model_s
| extend CacheHitRate = round(100.0 * CachedTokensIn / TokensIn, 1)
| order by CacheHitRate desc
```

**Specific key**:
```kusto
LiteLLMUsage_CL
| where KeyHash_s == "a3f7b2d9e4f1a9c2"
| where TimeGenerated > ago(30d)
| summarize Requests = count(), TokensIn = sum(TokensIn_d) by bin(TimeGenerated, 1d)
```

**Failure analysis**:
```kusto
LiteLLMUsage_CL
| where Status_s == "failure"
| where TimeGenerated > ago(7d)
| summarize count() by ErrorType_s, Model_s
```

### CLI Tool

```bash
# Daily summary
python scripts/usage-report.py --workspace-id <workspace-id> --date 2026-04-15

# Date range
python scripts/usage-report.py --workspace-id <workspace-id> --from 2026-04-01 --to 2026-04-15

# Per-model breakdown
python scripts/usage-report.py --workspace-id <workspace-id> --date 2026-04-15 --group-by model

# Export to CSV
python scripts/usage-report.py --workspace-id <workspace-id> --from 2026-04-01 --to 2026-04-15 --format csv > usage.csv
```

**Authentication**:
- Uses Azure CLI credentials by default (`az login`)
- Or set `LOG_ANALYTICS_WORKSPACE_ID` environment variable

## Cost Tracking Status

> **Cost is currently suppressed** — the `Cost_d` column is always `0` in new rows.

### Why

LiteLLM can estimate per-request cost using its internal pricing map. However, many Azure-deployed models bill cached input tokens at a significantly lower rate than non-cached tokens. Until the cached-token split is confirmed accurate for each deployed model alias, showing the naively-computed (uncached) estimate would overstate actual costs and cause confusion.

### What Is Logged Instead

The raw token counts needed to compute correct cost later are fully available:

| Field | Use |
|-------|-----|
| `TokensIn_d` | Total prompt tokens |
| `NonCachedTokensIn_d` | Prompt tokens billed at full input rate |
| `CachedTokensIn_d` | Prompt tokens billed at the (lower) cache-read rate |
| `TokensOut_d` | Completion tokens |

Once per-model cache pricing is validated, cost can be computed retroactively from these fields without needing a new deployment.

### Next Steps for Cost

1. Confirm per-model cached-token pricing (from Azure pricing pages or LiteLLM's pricing map)
2. Add explicit `cache_read_input_token_cost` overrides per model in `openai.tf` / `config.yaml.tpl` if needed
3. Re-enable `Cost` logging in `infra/usage_callback.py` once estimates are trusted

## Infrastructure Cost

| Component | Monthly Cost (Approximate) |
|-----------|---------------------------|
| Log Analytics ingestion | ~$2.50 per GB |

**Example**: 1,000 requests/day = ~1MB/day = ~30MB/month → **<$0.10/month**

Usage tracking adds negligible cost to your existing Log Analytics workspace.

## Privacy & Security

### Key Hashing

- API keys are **never stored in plain text**
- Only the first 16 characters of the SHA-256 hash are stored
- Hash is stable across deployments (same key → same hash)
- Cannot be reversed to recover the original key

### No Content Logging

- **Prompts and responses are NOT logged**
- Only metadata: key hash, model, token counts, cost, status
- Aligns with existing Log Analytics policy (metadata-only)

### Log Analytics Security

- Data stored in your Azure subscription
- Access controlled via Azure RBAC
- Encrypted at rest and in transit
- Retention configured per workspace (default: 30 days)

## Failure Analysis

Failed requests are logged with minimal error categorization:

| Error Type | Description |
|------------|-------------|
| `AuthenticationError` | Invalid/expired API key |
| `RateLimit` | Quota exceeded |
| `Timeout` | Request timeout |
| `ValidationError` | Invalid request format |
| `Unknown` | Other errors |

Query failures in Log Analytics:
```kusto
LiteLLMUsage_CL
| where Status_s == "failure"
| where TimeGenerated > ago(7d)
| summarize count() by ErrorType_s, Model_s
```

## Retention

- **Configured per Log Analytics workspace**
- Default: 30 days
- Can be extended up to 730 days (or unlimited with archive)

## Troubleshooting

### No Data Showing

1. Check callback logs in Container App:
   ```bash
   az containerapp logs show --name litellm-proxy --resource-group AzureLIT-POC --follow
   ```

2. Look for errors like `[usage_callback] ERROR logging usage`

3. Verify Log Analytics workspace credentials are set

4. Test query directly in Log Analytics:
   ```kusto
   LiteLLMUsage_CL | take 10
   ```

### High Latency on Writes

Callback is fire-and-forget (async). If Log Analytics is slow, it will log to stdout but won't block requests.

### Cost Data Missing / Always Zero

`Cost_d` is intentionally set to `0` in all current rows. See [Cost Tracking Status](#cost-tracking-status). This is by design, not an error.

## CLI Reference

```bash
usage: usage-report.py [-h] [--workspace-id WORKSPACE_ID] [--date DATE]
                       [--from DATE_FROM] [--to TO] [--key-hash KEY_HASH]
                       [--group-by {key,model}] [--format {table,csv,json}]

AzureLIT Usage Report

options:
  -h, --help            show this help message and exit
  --workspace-id        Log Analytics workspace ID
  --date                Single date (YYYY-MM-DD)
  --from                Start date (YYYY-MM-DD)
  --to                  End date (YYYY-MM-DD)
  --key-hash            Filter to specific key
  --group-by            Aggregation level (key or model)
  --format              Output format (table, csv, json)
```

## Next Steps

### Immediate (Cost Accuracy)

- [ ] Validate cached-token pricing for each deployed model alias against Azure pricing pages
- [ ] Add `cache_read_input_token_cost` / `cache_creation_input_token_cost` overrides in `openai.tf` where needed
- [ ] Re-enable cost logging in `infra/usage_callback.py` once estimates are trusted
- [ ] Update `scripts/usage-report.py` to show cache hit rate and cost columns once cost is active

### v2 Enhancements (Optional)

- [ ] Key alias mapping (human-readable labels)
- [ ] Budget alerts (threshold-based notifications via Azure Monitor)
- [ ] Scheduled reports (email via Logic Apps)
- [ ] GitHub Action for automated reporting

### Advanced KQL Dashboards

Create Azure Workbooks for visualization:
- Daily/weekly usage trends
- Cache hit rate by model
- Model popularity
- Error rate monitoring

Example workbook query for cache hit rate trend:
```kusto
LiteLLMUsage_CL
| where TimeGenerated > ago(30d)
| where Status_s == "success" and TokensIn_d > 0
| summarize
    TokensIn = sum(TokensIn_d),
    CachedTokensIn = sum(CachedTokensIn_d)
    by bin(TimeGenerated, 1d)
| extend CacheHitRate = round(100.0 * CachedTokensIn / TokensIn, 1)
| render timechart
```
