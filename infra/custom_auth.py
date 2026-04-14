"""
Custom auth handler for LiteLLM Proxy.

Validates incoming Bearer tokens against a set of allowed API keys injected via
the API_KEYS environment variable (comma-separated). The LITELLM_MASTER_KEY is
also accepted so admin operations (e.g. /key/generate, /model/info) keep working.

Keys are loaded once on first request and cached for the lifetime of the process.
To rotate keys: update the Container App secret and redeploy (terraform apply).

Config reference:
  general_settings:
    custom_auth: custom_auth.user_api_key_auth
"""

import os
from fastapi import Request
from litellm.proxy._types import UserAPIKeyAuth

_valid_keys: set[str] | None = None


def _load_keys() -> set[str]:
    global _valid_keys
    if _valid_keys is None:
        keys: set[str] = set()

        # Client API keys — comma-separated, set via TF_VAR_api_keys → Container secret
        raw = os.environ.get("API_KEYS", "")
        keys.update(k.strip() for k in raw.split(",") if k.strip())

        # Master key must also pass — custom_auth runs before LiteLLM's built-in
        # master_key check and replaces it entirely when set.
        master = os.environ.get("LITELLM_MASTER_KEY", "")
        if master:
            keys.add(master)

        if not keys:
            raise RuntimeError(
                "Proxy misconfiguration: neither API_KEYS nor LITELLM_MASTER_KEY is set"
            )

        _valid_keys = keys

    return _valid_keys


async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    # Allow health check endpoints through without authentication so that
    # Azure Container Apps probes can reach them without a Bearer token.
    if request.url.path.startswith("/health/"):
        return UserAPIKeyAuth(api_key="health-probe")

    if api_key not in _load_keys():
        raise Exception("Invalid API key")
    return UserAPIKeyAuth(api_key=api_key)
