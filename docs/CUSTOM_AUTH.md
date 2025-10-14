# LiteLLM Proxy Custom Auth (Context and Future Use)

This project previously experimented with LiteLLM `custom_auth` in the PoC, but it was removed due to integration friction. After consulting a subject matter expert and validating in tests, we confirmed that setting a MASTER_KEY alone does enforce client authentication on the LiteLLM Proxy. Therefore, the PoC now relies on MASTER_KEY-only authentication and does not use `custom_auth`.

## Current PoC Authentication Model

- MASTER_KEY configured via environment variable `LITELLM_MASTER_KEY` or `general_settings.master_key` in `config.yaml`.
- Clients MUST send `Authorization: Bearer <MASTER_KEY>` to access `/v1/*` endpoints.
- No database is used; all clients share the same credential (the MASTER_KEY).
- If no MASTER_KEY is set, the proxy is unauthenticated (development-only).

## When to Consider Custom Auth

`custom_auth` can be reintroduced in future phases (or MVP) when:
- You want to validate against a custom key store (e.g., Azure Table Storage) without enabling LiteLLM virtual keys.
- You need additional request-time checks (IP restrictions, header validations, or tenant routing).
- You want to enforce rules beyond simple bearer token equality.

In such cases, `custom_auth` would wrap your key validation logic and run before the proxy executes the request.

## Alternative for Multi-Client Production

For per-client keys, budgets, and permissions, use LiteLLM Virtual Keys (requires a database). This enables:
- Individual API keys for each client/user/team.
- Spend tracking and quotas.
- Admin UI for key management.

See: https://docs.litellm.ai/docs/proxy/virtual_keys

## References

- PoC authentication details: see `docs/MASTER_KEY_MANAGEMENT.md` and `docs/POC.md`.
- LiteLLM docs: https://docs.litellm.ai/docs/
