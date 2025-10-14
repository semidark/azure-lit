# Minimal custom auth to enforce a single master key for LiteLLM Proxy
# Validates the incoming Authorization: Bearer <key> strictly against LITELLM_MASTER_KEY

import os
from fastapi import Request
from litellm.proxy._types import UserAPIKeyAuth

MASTER_KEY_ENV = "LITELLM_MASTER_KEY"

async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    required_key = os.environ.get(MASTER_KEY_ENV)
    if not required_key:
        # Fail closed if the master key is not set on the container
        raise Exception("Proxy misconfiguration: master key not set")

    # LiteLLM convention often expects keys to start with 'sk-'; we don't enforce format here,
    # only exact equality to the configured secret.
    if api_key == required_key:
        # Optionally restrict to specific model aliases if needed via `models=["gpt-4.1"]`
        return UserAPIKeyAuth(api_key=api_key)

    raise Exception("Invalid API key")
