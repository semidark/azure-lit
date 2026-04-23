"""
LiteLLM callback handler for usage tracking to Log Analytics.
Implements CustomLogger interface for async success/failure event logging.

Environment:
  LOG_ANALYTICS_CUSTOMER_ID - Log Analytics workspace ID
  LOG_ANALYTICS_KEY         - Log Analytics shared key
  USAGE_LOG_TYPE            - Log type name (default: LiteLLMUsage)
"""

import asyncio
import base64
import hashlib
import hmac
import json
import os
from datetime import datetime, timezone

import httpx
from litellm.integrations.custom_logger import CustomLogger


_LOG_TYPE = os.environ.get("USAGE_LOG_TYPE", "LiteLLMUsage")


def _hash_key(api_key: str) -> str:
    """Return SHA-256 hash of api_key for privacy.

    Used only as a last-resort fallback. The primary key identifier is
    LiteLLM's internal user_api_key hash from litellm_params metadata,
    which is a full 64-char SHA-256 hex string derived from the client Bearer token.
    """
    return hashlib.sha256(api_key.encode()).hexdigest()


def _as_int(value) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _detail_value(details, key: str, default=0):
    if isinstance(details, dict):
        return details.get(key, default)
    return getattr(details, key, default)


def _extract_usage(kwargs: dict, response_obj: dict) -> dict:
    """Extract token counts from LiteLLM callback payload."""
    usage = response_obj.get("usage", {}) if response_obj else {}
    prompt_token_details = usage.get("prompt_tokens_details", {})

    prompt_tokens = _as_int(usage.get("prompt_tokens", 0))
    cached_prompt_tokens = _as_int(_detail_value(prompt_token_details, "cached_tokens"))
    cache_creation_input_tokens = _as_int(
        _detail_value(prompt_token_details, "cache_creation_input_tokens")
    )

    return {
        "TokensIn": prompt_tokens,
        "TokensOut": _as_int(usage.get("completion_tokens", 0)),
        "CachedTokensIn": cached_prompt_tokens,
        "NonCachedTokensIn": max(prompt_tokens - cached_prompt_tokens, 0),
        "CacheWriteTokensIn": cache_creation_input_tokens,
    }


async def _send_to_log_analytics(
    client: httpx.AsyncClient,
    workspace_id: str,
    shared_key: str,
    log_type: str,
    records: list,
):
    """Send records to Log Analytics custom table via HTTP Data Collector API."""
    customer_id = workspace_id
    timestamp = datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S GMT"
    )  # RFC 1123

    # Calculate content length in bytes
    body = json.dumps(records).encode("utf-8")
    content_length = len(body)

    # Build signature string per Azure docs
    # StringToSign = VERB + "\n" + Content-Length + "\n" + Content-Type + "\n" + "x-ms-date:" + x-ms-date + "\n" + "/api/logs"
    string_to_sign = (
        f"POST\n{content_length}\napplication/json\nx-ms-date:{timestamp}\n/api/logs"
    )

    # Calculate HMAC-SHA256 signature
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

    response = await client.post(url, content=body, headers=headers)
    if response.status_code not in [200, 204]:
        raise Exception(
            f"Log Analytics API returned {response.status_code}: {response.text}"
        )


async def _send_with_retry(
    client: httpx.AsyncClient,
    workspace_id: str,
    shared_key: str,
    log_type: str,
    records: list,
    max_retries: int = 2,
):
    """Attempt to send records with exponential backoff on failure."""
    for attempt in range(max_retries + 1):
        try:
            await _send_to_log_analytics(
                client, workspace_id, shared_key, log_type, records
            )
            return
        except Exception as e:
            if attempt < max_retries:
                delay = 2**attempt
                print(
                    f"[usage_callback] retry {attempt + 1}/{max_retries} in {delay}s: {e}",
                    flush=True,
                )
                await asyncio.sleep(delay)
            else:
                raise


class UsageLogger(CustomLogger):
    """Custom logger that sends usage data to Azure Log Analytics."""

    def __init__(self):
        self.workspace_id = os.environ.get("LOG_ANALYTICS_CUSTOMER_ID")
        self.shared_key = os.environ.get("LOG_ANALYTICS_KEY")
        self.log_type = _LOG_TYPE
        self._client = httpx.AsyncClient(timeout=10.0)
        print("[usage_callback] UsageLogger initialized", flush=True)

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        """
        Async callback for successful requests.
        Called by LiteLLM after a successful completion.
        """
        try:
            # kwargs["api_key"] is the upstream provider key (e.g. Azure Cognitive Services key),
            # not the client's Bearer token. The authorization header is stripped from
            # proxy_server_request for security. Use LiteLLM's internal user_api_key hash,
            # which is a stable per-client identifier derived from the original Bearer token.
            litellm_params = kwargs.get("litellm_params", {})
            metadata = litellm_params.get("metadata", {})
            # user_api_key in metadata is LiteLLM's hash of the client key
            key_hash = (
                metadata.get("user_api_key")
                or metadata.get("user_api_key_hash")
                or _hash_key(kwargs.get("api_key", ""))
            )

            if not key_hash:
                return
            model = kwargs.get("model", "unknown")

            usage = _extract_usage(kwargs, response_obj)

            # Extract cost calculated by LiteLLM (if available)
            response_cost = kwargs.get("response_cost", 0) or 0

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
                "Cost": round(response_cost, 10),
                "Status": "success",
            }
            if not self.workspace_id or not self.shared_key:
                print(
                    "[usage_callback] Log Analytics credentials not configured",
                    flush=True,
                )
                return

            await _send_with_retry(
                self._client,
                self.workspace_id,
                self.shared_key,
                self.log_type,
                [record],
            )

        except Exception as e:
            print(f"[usage_callback] ERROR logging success: {e}", flush=True)

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        """
        Async callback for failed requests.
        Called by LiteLLM after a failure.
        """
        try:
            # Same extraction logic as async_log_success_event.
            litellm_params = kwargs.get("litellm_params", {})
            metadata = litellm_params.get("metadata", {})
            key_hash = (
                metadata.get("user_api_key")
                or metadata.get("user_api_key_hash")
                or _hash_key(kwargs.get("api_key", ""))
            )

            if not key_hash:
                return
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

            await _send_with_retry(
                self._client,
                self.workspace_id,
                self.shared_key,
                self.log_type,
                [record],
            )

        except Exception as e:
            print(f"[usage_callback] ERROR logging failure: {e}", flush=True)


# Export instance for LiteLLM to import
proxy_handler_instance = UsageLogger()
