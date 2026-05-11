# Prompt Caching for AzureLIT

## Overview

Prompt caching reduces latency by up to 80% and input token costs by up to 90% for Azure OpenAI models. AzureLIT's LiteLLM proxy preserves OpenAI's native prompt caching semantics for supported models.

**No proxy configuration changes are required.** Caching works automatically when you structure prompts correctly.

## Supported Models

Verified in this deployment:

| Model | Cache Retention | Status |
|-------|----------------|--------|
| `gpt-4.1` | `in_memory` (5-10 min) or `24h` | ✅ Tested |
| `gpt-5.4` | `in_memory` or `24h` | ✅ Supported |
| `gpt-5.1-codex` | `in_memory` or `24h` | ✅ Supported |

Other models may support caching but have not been explicitly tested in this deployment.

## How It Works

1. **Automatic activation**: Caching enables automatically for prompts with 1024+ tokens
2. **Cache routing**: Requests with identical prefixes route to the same backend machine
3. **Cache lookup**: The system checks if the prompt prefix exists in GPU memory
4. **Cache hit**: Matching prefix returns cached intermediate results (faster, cheaper)
5. **Cache miss**: Full prompt processing occurs, then caches the prefix for future requests

## Prompt Structure Guidelines

### ✅ Do This

**Place static content first:**
```python
messages = [
    {
        "role": "system",
        "content": """
        You are an expert legal document analyzer. Your task is to extract key terms from contracts.

        Here is the contract text to analyze:
        [LONG STATIC CONTEXT - instructions, examples, domain knowledge]
        [LONG STATIC CONTEXT - rules, formatting requirements]
        """
    },
    {
        "role": "user",
        "content": "What are the termination clauses in this specific contract?"  # Variable part last
    }
]
```

**Use `prompt_cache_key` for shared workloads:**
```python
extra_body = {
    "prompt_cache_key": "legal-contract-analysis-v1"  # Stable identifier for this workload
}
```

**Use extended retention for recurring tasks:**
```python
extra_body = {
    "prompt_cache_key": "daily-report-template",
    "prompt_cache_retention": "24h"  # Keep cache for up to 24 hours
}
```

### ❌ Don't Do This

**Avoid volatile content at the start:**
```python
# BAD - timestamp at the beginning breaks cache
messages = [
    {"role": "system", "content": f"Request at {datetime.now()}: Analyze this..."},
    {"role": "user", "content": "Contract text..."}
]

# BAD - UUID in system prompt
messages = [
    {"role": "system", "content": f"Session {uuid4()}: You are an assistant..."},
    {"role": "user", "content": "Contract text..."}
]
```

## Validation Tests

The following tests confirm prompt caching works in your deployment:

### Test 1: Basic Cache Hit

```bash
ENDPOINT="https://litellm-proxy.purplegrass-c448b43e.germanywestcentral.azurecontainerapps.io"
API_KEY="sk-JuQmWbOySI2m86b7"

LONG_SYSTEM_PROMPT=$(python3 -c "print('You are an expert AI assistant. Here is the context: ' * 200)")

# First request (cache miss)
curl -sS -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-4.1\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"$LONG_SYSTEM_PROMPT\"},
      {\"role\": \"user\", \"content\": \"What is 2+2?\"}
    ],
    \"stream\": false
  }" "$ENDPOINT/v1/chat/completions" | jq '.usage.prompt_tokens_details'

# Second identical request (should show cached_tokens > 0)
curl -sS -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-4.1\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"$LONG_SYSTEM_PROMPT\"},
      {\"role\": \"user\", \"content\": \"What is 3+3?\"}
    ],
    \"stream\": false
  }" "$ENDPOINT/v1/chat/completions" | jq '.usage.prompt_tokens_details'
```

Expected output for second request:
```json
{
  "cached_tokens": 2816,
  "other_tokens": 203
}
```

### Test 2: With prompt_cache_key

```bash
curl -sS -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-4.1\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"$LONG_SYSTEM_PROMPT\"},
      {\"role\": \"user\", \"content\": \"Query 1\"}
    ],
    \"extra_body\": {
      \"prompt_cache_key\": \"my-workload-key\"
    },
    \"stream\": false
  }" "$ENDPOINT/v1/chat/completions" | jq '.usage.prompt_tokens_details'

# Repeat with same prompt_cache_key - should show cached tokens
```

### Test 3: Check Model Support

```bash
curl -sS -H "Authorization: Bearer $API_KEY" \
  "$ENDPOINT/v1/model/info" | jq '.data[] | select(.model_name == "gpt-4.1") | {model_name, supports_prompt_caching}'
```

Expected:
```json
{
  "model_name": "gpt-4.1",
  "supports_prompt_caching": true
}
```

## Monitoring Cache Performance

### Via Response Usage

Every response includes usage details:

```python
from openai import OpenAI

client = OpenAI(
    api_key="sk-client-key",
    base_url="https://litellm-proxy.purplegrass-c448b43e.germanywestcentral.azurecontainerapps.io"
)

response = client.chat.completions.create(
    model="gpt-4.1",
    messages=[...],
    extra_body={"prompt_cache_key": "workload-A"}
)

print(f"Total prompt tokens: {response.usage.prompt_tokens}")
print(f"Cached tokens: {response.usage.prompt_tokens_details.cached_tokens}")
print(f"Cache hit rate: {response.usage.prompt_tokens_details.cached_tokens / response.usage.prompt_tokens * 100:.1f}%")
```

### Via Log Analytics

The `UsageMetrics` table tracks cache usage:

```kusto
UsageMetrics
| where TimeGenerated > ago(7d)
| where Model_s == "gpt-4.1"
| summarize
    TotalPromptTokens = sum(PromptTokens_d),
    CachedTokens = sum(CachedTokensIn_d),
    CacheHitRate = sum(CachedTokensIn_d) * 100.0 / sum(PromptTokens_d)
    by bin(TimeGenerated, 1d)
| render timechart
```

**Key fields:**
- `CachedTokensIn_d`: Tokens served from cache
- `NonCachedTokensIn_d`: Fresh prompt tokens processed
- `PromptTokens_d`: Total input tokens

### Cache Hit Rate Guidelines

- **>70%**: Excellent - workload has strong repetition patterns
- **50-70%**: Good - some variability in prompts
- **<50%**: Review prompt structure - consider consolidating static content

## Cost Impact

Cached tokens are billed at a reduced rate. For `gpt-4.1`:

- **Non-cached prompt tokens**: Standard input pricing
- **Cached prompt tokens**: ~10-20% of standard input pricing

Example savings for a 3000-token prompt with 2800 cached:
- Without caching: 3000 × $0.000025 = $0.075
- With caching: 200 × $0.000025 + 2800 × $0.000005 ≈ $0.019
- **Savings: ~75%**

## Best Practices

### For Development Teams

1. **Audit prompt structures**: Move static content to system messages
2. **Standardize cache keys**: Use meaningful, stable identifiers per workload type
3. **Monitor before/after**: Track cache hit rates during rollout
4. **Set retention policies**: Use `24h` for daily recurring tasks

### For Workload Types

**High-value caching candidates:**
- Code generation with shared codebases
- Document analysis with fixed templates
- Customer support with knowledge bases
- Multi-turn conversations with persistent context

**Lower-value caching candidates:**
- One-off queries with unique context
- Highly variable input lengths
- Real-time data that changes frequently

## Troubleshooting

### No Cache Hits

**Checklist:**
1. ✅ Prompt length ≥ 1024 tokens?
2. ✅ Static content at the beginning?
3. ✅ Identical prefix between requests?
4. ✅ Same `prompt_cache_key` (if used)?
5. ✅ Requests within cache TTL (5-10 min default, 24h with extended retention)?

**Common issues:**
- Timestamps/UUIDs in system prompt
- User-specific data at the start
- Different model versions
- Cache overflow (high request rate >15/min per cache key)

### Parameters Being Dropped

If `prompt_cache_key` or `prompt_cache_retention` are not working:

1. Verify model supports caching via `/v1/model/info`
2. Check LiteLLM version compatibility

The current deployment has validated that these parameters survive filtering for `gpt-4.1`.

## Security Notes

- **Data isolation**: Caches are isolated per Azure organization
- **No prompt logging**: Proxy does not log prompt/response content
- **Cache eviction**: Automatic after TTL expiration
- **Zero data retention**: Extended caching (`24h`) may store key-value tensors temporarily on GPU machines

## References

- [OpenAI Prompt Caching Guide](https://platform.openai.com/docs/guides/prompt-caching)
- [Azure OpenAI Prompt Caching](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/prompt-caching)
- [LiteLLM Prompt Caching](https://docs.litellm.ai/docs/completion/prompt_caching)
