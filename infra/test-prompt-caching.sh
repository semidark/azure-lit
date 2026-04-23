#!/bin/bash
# Test prompt caching for AzureLIT deployment
# Validates that prompt caching works correctly for gpt-4.1

set -e

ENDPOINT="${ENDPOINT:-https://litellm-proxy.purplegrass-c448b43e.germanywestcentral.azurecontainerapps.io}"
API_KEY="${API_KEY:-sk-JuQmWbOySI2m86b7}"

echo "=========================================="
echo "AzureLIT Prompt Caching Validation Test"
echo "=========================================="
echo ""
echo "Endpoint: $ENDPOINT"
echo "Model: gpt-4.1"
echo ""

# Check if model supports prompt caching
echo "Step 1: Checking model support..."
MODEL_INFO=$(curl -sS -H "Authorization: Bearer $API_KEY" "$ENDPOINT/v1/model/info")
SUPPORTS_PC=$(echo "$MODEL_INFO" | jq -r '.data[] | select(.model_name == "gpt-4.1") | .model_info.supports_prompt_caching')

if [ "$SUPPORTS_PC" == "true" ]; then
    echo "✅ gpt-4.1 supports prompt caching"
else
    echo "❌ gpt-4.1 does not report prompt caching support"
    exit 1
fi

echo ""
echo "Step 2: Running cache test..."

# Create a long stable system prompt (3000+ tokens)
LONG_SYSTEM_PROMPT=$(python3 -c "print('You are an expert AI assistant. Here is the context for our conversation: ' * 200)")

# First request (cache miss expected)
echo "Running first request (cache miss expected)..."
RESPONSE1=$(curl -sS -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-4.1\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"$LONG_SYSTEM_PROMPT\"},
      {\"role\": \"user\", \"content\": \"What is 2+2?\"}
    ],
    \"stream\": false
  }" "$ENDPOINT/v1/chat/completions")

CACHED1=$(echo "$RESPONSE1" | jq -r '.usage.prompt_tokens_details.cached_tokens')
TOTAL1=$(echo "$RESPONSE1" | jq -r '.usage.prompt_tokens')

echo "  First request: $TOTAL1 prompt tokens, $CACHED1 cached"

# Second request (cache hit expected)
echo "Running second request (cache hit expected)..."
RESPONSE2=$(curl -sS -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-4.1\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"$LONG_SYSTEM_PROMPT\"},
      {\"role\": \"user\", \"content\": \"What is 3+3?\"}
    ],
    \"stream\": false
  }" "$ENDPOINT/v1/chat/completions")

CACHED2=$(echo "$RESPONSE2" | jq -r '.usage.prompt_tokens_details.cached_tokens')
TOTAL2=$(echo "$RESPONSE2" | jq -r '.usage.prompt_tokens')

echo "  Second request: $TOTAL2 prompt tokens, $CACHED2 cached"

# Test with prompt_cache_key
echo ""
echo "Step 3: Testing with prompt_cache_key..."

echo "Running first request with cache key..."
RESPONSE3=$(curl -sS -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-4.1\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"$LONG_SYSTEM_PROMPT\"},
      {\"role\": \"user\", \"content\": \"What is 4+4?\"}
    ],
    \"extra_body\": {
      \"prompt_cache_key\": \"test-workload-validation\"
    },
    \"stream\": false
  }" "$ENDPOINT/v1/chat/completions")

CACHED3=$(echo "$RESPONSE3" | jq -r '.usage.prompt_tokens_details.cached_tokens')
TOTAL3=$(echo "$RESPONSE3" | jq -r '.usage.prompt_tokens')

echo "  First request with key: $TOTAL3 prompt tokens, $CACHED3 cached"

echo "Running second request with same cache key..."
RESPONSE4=$(curl -sS -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-4.1\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"$LONG_SYSTEM_PROMPT\"},
      {\"role\": \"user\", \"content\": \"What is 5+5?\"}
    ],
    \"extra_body\": {
      \"prompt_cache_key\": \"test-workload-validation\"
    },
    \"stream\": false
  }" "$ENDPOINT/v1/chat/completions")

CACHED4=$(echo "$RESPONSE4" | jq -r '.usage.prompt_tokens_details.cached_tokens')
TOTAL4=$(echo "$RESPONSE4" | jq -r '.usage.prompt_tokens')

echo "  Second request with key: $TOTAL4 prompt tokens, $CACHED4 cached"

# Summary
echo ""
echo "=========================================="
echo "Test Results"
echo "=========================================="

PASSED=true

if [ "$CACHED2" -gt 0 ]; then
    echo "✅ Basic cache hit: $CACHED2 tokens cached out of $TOTAL2"
else
    echo "❌ Basic cache hit: No cache hit detected (expected > 0)"
    PASSED=false
fi

if [ "$CACHED4" -gt 0 ]; then
    HIT_RATE=$(echo "scale=1; $CACHED4 * 100 / $TOTAL4" | bc)
    echo "✅ Cache with key: $CACHED4 tokens cached out of $TOTAL4 ($HIT_RATE% hit rate)"
else
    echo "❌ Cache with key: No cache hit detected (expected > 0)"
    PASSED=false
fi

echo ""
if [ "$PASSED" = true ]; then
    echo "🎉 All tests passed! Prompt caching is working correctly."
    exit 0
else
    echo "⚠️  Some tests failed. Review prompt structure and requirements."
    echo "See docs/PROMPT_CACHING.md for troubleshooting guidance."
    exit 1
fi
