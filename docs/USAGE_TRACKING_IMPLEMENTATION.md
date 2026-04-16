# Usage Tracking Implementation Summary

## Overview

Usage tracking logs every request to Azure Log Analytics as a custom table (`LiteLLMUsage_CL`). The implementation uses a LiteLLM `CustomLogger` callback that fires on success/failure events, hashing API keys for privacy and capturing detailed token metrics including cache usage.

## What Was Implemented

### Core Infrastructure

1. **Log Analytics Custom Table** (existing workspace reused)
   - Table: `LiteLLMUsage_CL`
   - Cost: Negligible (part of existing Log Analytics ingestion)
   - No new resources created

2. **Usage Callback Handler** (`infra/usage_callback.py`)
   - LiteLLM `CustomLogger` with `async_log_success_event` / `async_log_failure_event`
   - SHA-256 hash of API keys (first 16 chars) for privacy
   - Async, fire-and-forget writes to Log Analytics
   - Captures: total tokens, cached tokens, non-cached tokens, cache-write tokens, model, status, error type
   - `Cost` field is set to `0` — suppressed until cached-token pricing is validated (see `docs/USAGE_ANALYSIS.md`)
   - Uses Log Analytics HTTP Data Collector API with `time-generated-field` header to avoid duplicate timestamp columns

3. **Configuration** (`infra/config.yaml.tpl`)
   - Registered callbacks in LiteLLM config
   - Automatic on every request

4. **Container App Updates** (`infra/main.tf`)
   - New secret: `usage-callback-py`, `log-analytics-key`
   - New env vars: `LOG_ANALYTICS_CUSTOMER_ID`, `LOG_ANALYTICS_KEY`, `USAGE_LOG_TYPE`
   - Entrypoint copies `usage_callback.py` to container

### Reporting Tool

**`scripts/usage-report.py`** - CLI for querying usage via Log Analytics

```bash
# Daily summary
python scripts/usage-report.py --workspace-id <workspace-id> --date 2026-04-15

# Date range
python scripts/usage-report.py --workspace-id <workspace-id> --from 2026-04-01 --to 2026-04-15

# Per-model breakdown
python scripts/usage-report.py --workspace-id <workspace-id> --date 2026-04-15 --group-by model

# Export formats
python scripts/usage-report.py --workspace-id <workspace-id> --from 2026-04-01 --to 2026-04-15 --format csv
python scripts/usage-report.py --workspace-id <workspace-id> --from 2026-04-01 --to 2026-04-15 --format json
```

**Dependencies**: `pip install -r scripts/requirements.txt`

### Documentation

- **`docs/USAGE_ANALYSIS.md`** - Complete feature documentation
  - Architecture overview
  - Schema reference
  - KQL query examples
  - CLI usage
  - Cost estimation
  - Privacy considerations
  - Troubleshooting

## Files Changed/Created (Commit e4a16c2)

| File | Action | Purpose |
|------|--------|---------|
| `infra/usage_callback.py` | **NEW** | LiteLLM `CustomLogger` callback handler for async success/failure event logging to Log Analytics |
| `infra/main.tf` | **MODIFIED** | Added `usage-callback-py` secret, `log-analytics-key` secret, env vars (`LOG_ANALYTICS_CUSTOMER_ID`, `LOG_ANALYTICS_KEY`, `USAGE_LOG_TYPE`), container command updates to copy `usage_callback.py` |
| `infra/config.yaml.tpl` | **MODIFIED** | Registered `callbacks: usage_callback.proxy_handler_instance`; added conditional `model_info` fields (`base_model`, `input_cost_per_token`, `output_cost_per_token`) for cost tracking support |
| `infra/outputs.tf` | **MODIFIED** | Added `log_analytics_workspace_id` and `usage_query_example` outputs for KQL query access |
| `infra/openai.tf` | **MODIFIED** | Extended `var.models` type with `base_model`, `input_cost_per_token`, `output_cost_per_token` optional fields |
| `infra/main.tf` (Defender) | **MODIFIED** | Added `azurerm_security_center_subscription_pricing` for AI Services (Free tier) with detailed security documentation |
| `docs/USAGE_TRACKING_IMPLEMENTATION.md` | **MODIFIED** | Updated implementation summary |
| `docs/USAGE_ANALYSIS.md` | **MODIFIED** | Updated feature documentation |

## Schema

Log Analytics appends type suffixes automatically (e.g. `KeyHash` → `KeyHash_s`, `TokensIn` → `TokensIn_d`).

**LiteLLMUsage_CL table (Log Analytics custom log):**

| Field | Type | Description |
|-------|------|-------------|
| `TimeGenerated` | datetime | Request timestamp (UTC) |
| `KeyHash_s` | string | First 16 chars of SHA-256 hash of API key (privacy-preserving) |
| `Model_s` | string | Model alias (e.g., `gpt-4.1`, `gpt-5.4`) |
| `TokensIn_d` | real | Total prompt tokens (cached + non-cached) |
| `TokensOut_d` | real | Completion tokens generated |
| `CachedTokensIn_d` | real | Prompt tokens served from cache (cache hit) |
| `NonCachedTokensIn_d` | real | Prompt tokens not in cache (billed at full rate) |
| `CacheWriteTokensIn_d` | real | Prompt tokens written to cache (typically 0 for Azure/OpenAI) |
| `Cost_d` | real | LiteLLM-calculated response cost |
| `Status_s` | string | `"success"` or `"failure"` |
| `ErrorType_s` | string | (Failures only) `AuthenticationError` \| `RateLimit` \| `Timeout` \| `ValidationError` \| `Unknown` |

> **Legacy columns**: Rows ingested before the current callback version may contain duplicate suffixed columns (`KeyHash_s_s`, `Model_s_s`, `Status_s_s`). These are schema artifacts from the classic custom log table and will not appear in new rows. The reporting script normalises both forms.

## Deployment Steps

1. **Initialize Terraform** (if first time):
   ```bash
   cd infra
   terraform init
   ```

2. **Plan and Apply**:
   ```bash
   terraform plan -out=tfplan
   terraform apply tfplan
   ```

   This deploys:
   - Log Analytics workspace (if not existing)
   - Container App with usage tracking enabled
   - Defender for AI Services (Free tier) — monitors AI-specific threats
   - Outputs: `log_analytics_workspace_id`, `usage_query_example`

3. **Install CLI dependencies**:
   ```bash
   pip install -r scripts/requirements.txt
   ```

4. **Test the deployment**:
   ```bash
   # Make a test request
   curl -sS \
     -H "Authorization: Bearer sk-clientA" \
     -H "Content-Type: application/json" \
     -d '{"model": "gpt-4.1", "messages": [{"role": "user", "content": "Hi"}]}' \
     $(terraform -chdir=infra output -raw container_app_url)/v1/chat/completions

   # Wait 1-2 minutes for data to propagate to Log Analytics
   # Query via CLI
   python scripts/usage-report.py --workspace-id $(terraform -chdir=infra output -raw log_analytics_workspace_id) --date $(date +%Y-%m-%d)
   ```

   Or query directly in Log Analytics:
   ```kusto
   LiteLLMUsage_CL | where TimeGenerated > ago(5m) | take 10
   ```

## Verification Checklist

- [ ] Container App has new secrets (`usage-callback-py`, `log-analytics-key`)
- [ ] Container App has new env vars (`LOG_ANALYTICS_CUSTOMER_ID`, `LOG_ANALYTICS_KEY`, `USAGE_LOG_TYPE`)
- [ ] No errors in Container App logs (`az containerapp logs show`)
- [ ] Data appears in Log Analytics after test request
- [ ] CLI tool runs successfully

## Cost Impact

- **No new resources** - uses existing Log Analytics workspace
- **Ingestion cost**: ~1MB per 1,000 requests → ~30MB/month for typical usage
- **Monthly cost**: <$0.10 (negligible compared to existing Log Analytics)

## Privacy & Security

- ✅ API keys **never stored in plain text**
- ✅ Only 16-char SHA-256 hash prefix stored
- ✅ No prompt/response content logged
- ✅ Only metadata: tokens, cost, model, status
- ✅ Hash stable across deployments (same key → same hash)
- ✅ Data stored in your Azure subscription with RBAC access control

## Next Steps

### Ongoing

1. Verify data appears in Log Analytics after each deployment
2. Use cache-hit rate KQL queries to assess prompt caching effectiveness
3. Create Log Analytics saved queries for common reports

### Future Enhancements (v2)

- [ ] Key alias mapping (human-readable labels)
- [ ] Budget alerts via Azure Monitor
- [ ] Scheduled reports via Logic Apps
- [ ] Azure Workbook dashboards
