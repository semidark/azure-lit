"""
LiteLLM callback handler for usage tracking to Log Analytics.
Implements CustomLogger interface for async success/failure event logging.

Environment:
  LOG_ANALYTICS_CUSTOMER_ID - Log Analytics workspace ID
  LOG_ANALYTICS_KEY         - Log Analytics shared key
  USAGE_LOG_TYPE            - Log type name (default: LiteLLMUsage)
"""

import hashlib
import json
from datetime import datetime, timezone

import os
import requests
from litellm.integrations.custom_logger import CustomLogger


_LOG_TYPE = os.environ.get("USAGE_LOG_TYPE", "LiteLLMUsage")


def _hash_key(api_key: str) -> str:
    """Return first 16 chars of SHA-256 hash for privacy."""
    return hashlib.sha256(api_key.encode()).hexdigest()[:16]


def _as_int(value) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _extract_usage(kwargs: dict, response_obj: dict) -> dict:
    """Extract token counts from LiteLLM callback payload."""
    usage = response_obj.get("usage", {}) if response_obj else {}
    prompt_token_details = usage.get("prompt_tokens_details", {})

    prompt_tokens = _as_int(usage.get("prompt_tokens", 0))
    cached_prompt_tokens = _as_int(prompt_token_details.get("cached_tokens", 0))
    cache_creation_input_tokens = _as_int(
        prompt_token_details.get("cache_creation_input_tokens", 0)
    )

    return {
        "TokensIn": prompt_tokens,
        "TokensOut": _as_int(usage.get("completion_tokens", 0)),
        "CachedTokensIn": cached_prompt_tokens,
        "NonCachedTokensIn": max(prompt_tokens - cached_prompt_tokens, 0),
        "CacheWriteTokensIn": cache_creation_input_tokens,
    }


def _send_to_log_analytics(
    workspace_id: str, shared_key: str, log_type: str, records: list
):
    """Send records to Log Analytics custom table via HTTP Data Collector API."""
    customer_id = workspace_id
    timestamp = datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S GMT")  # RFC 1123

    # Calculate content length in bytes
    body = json.dumps(records)
    content_length = len(body.encode("utf-8"))

    # Build signature string per Azure docs
    # StringToSign = VERB + "\n" + Content-Length + "\n" + Content-Type + "\n" + "x-ms-date:" + x-ms-date + "\n" + "/api/logs"
    string_to_sign = (
        f"POST\n{content_length}\napplication/json\nx-ms-date:{timestamp}\n/api/logs"
    )

    # Calculate HMAC-SHA256 signature
    import hmac
    import base64

    key = base64.b64decode(shared_key)
    message = string_to_sign.encode("utf-8")
    signature = base64.b64encode(
        hmac.new(key, message, digestmod="sha256").digest()
    ).decode()

    # Build authorization header
    auth_header = f"SharedKey {customer_id}:{signature}"

    url = f"https://{customer_id}.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"

    headers = {
        "Content-Type": "application/json",
        "Authorization": auth_header,
        "x-ms-date": timestamp,
        "Log-Type": log_type,
    }

    # Let Log Analytics derive TimeGenerated from the payload field instead of
    # also storing the raw JSON property as a duplicate custom column.
    if records and all("TimeGenerated" in record for record in records):
        headers["time-generated-field"] = "TimeGenerated"

    response = requests.post(url, data=body, headers=headers, timeout=10)
    if response.status_code not in [200, 204]:
        raise Exception(
            f"Log Analytics API returned {response.status_code}: {response.text}"
        )


class UsageLogger(CustomLogger):
    """Custom logger that sends usage data to Azure Log Analytics."""

    def __init__(self):
        self.workspace_id = os.environ.get("LOG_ANALYTICS_CUSTOMER_ID")
        self.shared_key = os.environ.get("LOG_ANALYTICS_KEY")
        self.log_type = _LOG_TYPE
        print("[usage_callback] UsageLogger initialized", flush=True)

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        """
        Async callback for successful requests.
        Called by LiteLLM after a successful completion.
        """
        try:
            api_key = kwargs.get("api_key", "")
            if not api_key:
                return

            key_hash = _hash_key(api_key)
            model = kwargs.get("model", "unknown")

            usage = _extract_usage(kwargs, response_obj)

            now = datetime.now(timezone.utc)
            record = {
                "TimeGenerated": now.isoformat(),
                "KeyHash": key_hash,
                "Model": model,
                "TokensIn": usage["TokensIn"],
                "TokensOut": usage["TokensOut"],
                "CachedTokensIn": usage["CachedTokensIn"],
                "NonCachedTokensIn": usage["NonCachedTokensIn"],
                "CacheWriteTokensIn": usage["CacheWriteTokensIn"],
                # Keep cost suppressed until cached-token pricing is validated.
                "Cost": 0,
                "Status": "success",
            }
            if not self.workspace_id or not self.shared_key:
                print(
                    "[usage_callback] Log Analytics credentials not configured",
                    flush=True,
                )
                return

            _send_to_log_analytics(
                self.workspace_id, self.shared_key, self.log_type, [record]
            )

        except Exception as e:
            print(f"[usage_callback] ERROR logging success: {e}", flush=True)

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        """
        Async callback for failed requests.
        Called by LiteLLM after a failure.
        """
        try:
            api_key = kwargs.get("api_key", "")
            if not api_key:
                return

            key_hash = _hash_key(api_key)
            model = kwargs.get("model", "unknown")

            error_type = "Unknown"
            # response_obj contains exception info for failures
            if response_obj and isinstance(response_obj, dict):
                exc_name = str(
                    response_obj.get("exception", type(response_obj).__name__)
                )
                exc_lower = exc_name.lower()
                if "auth" in exc_lower or "key" in exc_lower:
                    error_type = "AuthenticationError"
                elif "rate" in exc_lower:
                    error_type = "RateLimit"
                elif "timeout" in exc_lower:
                    error_type = "Timeout"
                elif "validation" in exc_lower:
                    error_type = "ValidationError"

            now = datetime.now(timezone.utc)
            record = {
                "TimeGenerated": now.isoformat(),
                "KeyHash": key_hash,
                "Model": model,
                "TokensIn": 0,
                "TokensOut": 0,
                "CachedTokensIn": 0,
                "NonCachedTokensIn": 0,
                "CacheWriteTokensIn": 0,
                "Cost": 0,
                "Status": "failure",
                "ErrorType": error_type,
            }

            if not self.workspace_id or not self.shared_key:
                print(
                    "[usage_callback] Log Analytics credentials not configured",
                    flush=True,
                )
                return

            _send_to_log_analytics(
                self.workspace_id, self.shared_key, self.log_type, [record]
            )

        except Exception as e:
            print(f"[usage_callback] ERROR logging failure: {e}", flush=True)


# Export instance for LiteLLM to import
proxy_handler_instance = UsageLogger()
