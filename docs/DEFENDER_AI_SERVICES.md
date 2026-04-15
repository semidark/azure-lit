# Defender for AI Services

Microsoft Defender for AI Services provides threat protection for Azure AI workloads. This document covers the deployment configuration, security implications, and cost considerations.

## Overview

Defender for AI Services (formerly Defender for Cloud Apps - AI) monitors Azure AI Foundry (Cognitive Services) deployments for:

- **Prompt injection attacks** — Attempts to bypass safety filters via crafted prompts
- **Jailbreak attempts** — Efforts to circumvent model guardrails
- **Data exfiltration** — Unauthorized extraction of sensitive data through model responses
- **Model abuse** — Unusual usage patterns indicating malicious activity
- **Controversial content detection** — Generation of harmful, biased, or inappropriate content

## Deployment Configuration

Defender for AI Services is configured in `infra/main.tf`:

```hcl
resource "azurerm_security_center_subscription_pricing" "defender_ai" {
  tier          = "Free"
  resource_type = "AI"
}
```

### Why Free Tier?

The Free tier is set explicitly because:

1. **POC/Internal deployment** — API-key authenticated, trusted callers only
2. **Controlled input** — Prompts come from verified applications, not untrusted end-users
3. **Cost sensitivity** — Per-transaction billing (~$0.015 / 1,000 requests) accumulates quickly
4. **Existing protections** — Custom auth, model-level safety filters, and rate limiting provide baseline security

## Security Impact of Disabling (Free Tier)

| Capability | Status | Impact |
|------------|--------|--------|
| Real-time prompt injection detection | ❌ Disabled | No automated detection of adversarial prompts |
| Jailbreak attempt alerts | ❌ Disabled | No visibility into safety filter circumvention attempts |
| Data exfiltration monitoring | ❌ Disabled | Cannot detect unauthorized data extraction patterns |
| Threat intelligence integration | ❌ Disabled | No correlation with Microsoft's AI threat feeds |
| Security recommendations | ❌ Disabled | No guidance for improving AI security posture |

## When to Re-Enable (Standard Tier)

Re-enable Defender for AI Services (change `tier = "Standard"`) when:

- ✅ API is exposed to **untrusted users** or **public internet traffic**
- ✅ Input is **user-supplied** (e.g., chat interface, form submissions)
- ✅ **Compliance requirements** mandate AI threat monitoring
- ✅ **Security policy** requires defense-in-depth for AI workloads
- ✅ Budget allows for per-transaction costs at expected scale

### Enabling Standard Tier

```hcl
resource "azurerm_security_center_subscription_pricing" "defender_ai" {
  tier          = "Standard"
  resource_type = "AI"
}
```

## Cost Analysis

### Pricing Model

- **Billing**: Per transaction (~$0.015 per 1,000 requests)
- **Scope**: Subscription-level (all AI resources in subscription)
- **Billing frequency**: Monthly, separate from resource consumption costs

### Example Cost Scenarios

| Daily Requests | Monthly Requests | Estimated Monthly Cost |
|----------------|------------------|------------------------|
| 100            | 3,000            | $0.045                 |
| 1,000          | 30,000           | $0.45                  |
| 10,000         | 300,000          | $4.50                  |
| 100,000        | 3,000,000        | $45.00                 |

> **Note**: Costs are approximate and based on Microsoft's public pricing. Actual costs may vary by region and subscription agreement.

## Alternative Security Measures

With Defender disabled, the following controls provide baseline protection:

### 1. Custom Authentication (`custom_auth.py`)

- API-key based access control
- Key hashing for privacy
- No anonymous access

### 2. Model-Level Safety Filters

- Azure AI Content Safety (if enabled on model deployments)
- RAI (Responsible AI) policies attached to deployments
- Built-in safety filters from model providers

### 3. Infrastructure Hardening

- HTTPS-only ingress
- Private endpoints (optional, not configured)
- Container Apps network isolation
- Minimal replica count (0-2)

### 4. Usage Monitoring (Log Analytics)

- Per-key usage tracking
- Anomaly detection via KQL queries
- Failure analysis (rate limits, auth errors)

Example query for unusual usage patterns:

```kusto
LiteLLMUsage_CL
| where TimeGenerated > ago(24h)
| summarize Requests = count() by KeyHash_s
| where Requests > 1000
| order by Requests desc
```

## Monitoring and Alerts

### With Defender Standard Tier

Defender for AI Services provides:

- **Security alerts** via Azure Monitor
- **Security recommendations** in Defender for Cloud
- **Integrated dashboards** in Azure Portal
- **Threat intelligence** correlation

### With Free Tier (Current)

Use Log Analytics for monitoring:

```kusto
// Failed authentication attempts
LiteLLMUsage_CL
| where Status_s == "failure" and ErrorType_s == "AuthenticationError"
| where TimeGenerated > ago(24h)
| summarize Attempts = count() by KeyHash_s
| order by Attempts desc

// Rate limit events
LiteLLMUsage_CL
| where Status_s == "failure" and ErrorType_s == "RateLimit"
| where TimeGenerated > ago(24h)
| summarize Count = count() by Model_s, KeyHash_s
```

## Compliance Considerations

### Regulatory Requirements

| Framework | Defender Required? | Notes |
|-----------|-------------------|-------|
| SOC 2 | No | But recommended for "Security" trust principle |
| ISO 27001 | No | But supports A.12.6.1 (Technical vulnerabilities) |
| HIPAA | No | AI services not covered; focus on PHI protection |
| GDPR | No | But supports security of processing (Art. 32) |

### Internal Security Policy

If your organization requires:

- **Defense-in-depth** for AI workloads → Enable Standard tier
- **Threat detection** for adversarial attacks → Enable Standard tier
- **Audit trail** for security incidents → Enable Standard tier + Log Analytics

## Troubleshooting

### Defender Alerts (When Enabled)

Common alert types:

- **Prompt injection detected** — Review request logs, strengthen input validation
- **Jailbreak attempt** — Audit model safety filters, consider content moderation
- **Unusual data exfiltration pattern** — Investigate key usage, implement rate limiting

### Performance Impact

Defender for AI Services operates asynchronously and does not impact request latency. However:

- **Free tier**: No monitoring overhead
- **Standard tier**: Minimal overhead (~1-2ms per request for threat analysis)

## Related Documentation

- [Usage Tracking Implementation](USAGE_TRACKING_IMPLEMENTATION.md)
- [Usage Analysis](USAGE_ANALYSIS.md)
- [Custom Auth](CUSTOM_AUTH.md)
- [Architecture](ARCHITECTURE.md)

## References

- [Microsoft Defender for AI Services](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-ai-services)
- [AI Services Pricing](https://azure.microsoft.com/pricing/details/defender-for-cloud/)
- [Azure AI Content Safety](https://learn.microsoft.com/azure/ai-services/content-safety/)
