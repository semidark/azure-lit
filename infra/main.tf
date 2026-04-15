terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.55.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0.0"
    }
  }
}

variable "subscription_id" {
  description = "Azure subscription ID. Set via TF_VAR_subscription_id or a .tfvars file."
  type        = string
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

provider "azapi" {}

variable "location" {
  description = "Primary Azure region. Use lowercase-no-spaces to match model map region keys (e.g. germanywestcentral)."
  default     = "germanywestcentral"
}

variable "resource_group_name" {
  description = "Resource group name."
  default     = "AzureLIT-POC"
}

variable "litellm_master_key" {
  description = "Secure master key for LiteLLM. Set via TF_VAR_litellm_master_key."
  type        = string
  sensitive   = true
}

variable "api_keys" {
  description = "Comma-separated list of API keys for client auth (e.g. sk-key1,sk-key2). Set via TF_VAR_api_keys."
  type        = string
  sensitive   = true
}

# =============================================================================
# DEFENDER FOR CLOUD — AI SERVICES
# =============================================================================
#
# Microsoft Defender for AI Services (Standard tier) monitors all AIServices
# Cognitive Accounts in the subscription for prompt injection, jailbreak
# attempts, data exfiltration, and other AI-specific threats. It is billed
# per transaction (~$0.015 / 1,000 requests) at the subscription level —
# not per resource — so even low traffic accumulates visible charges.
#
# It is explicitly set to "Free" here (effectively disabled) because:
#   - This is a POC/internal deployment with trusted callers and API-key auth.
#   - Input never comes from untrusted end-users directly.
#   - The per-transaction cost is not justified at current usage levels.
#
# SECURITY IMPACT OF DISABLING:
#   - No real-time detection of prompt injection or jailbreak attacks.
#   - No Defender for Cloud alerts for AI-specific threat patterns.
#   - No integration with Microsoft Threat Intelligence for AI workloads.
#
# RE-ENABLE FOR PRODUCTION: Change tier to "Standard" (or remove this resource
# entirely — Standard is the Azure default) when:
#   - The API is exposed to untrusted users or public internet traffic.
#   - Input content is not fully controlled (e.g. user-supplied prompts).
#   - Compliance or security policy requires AI threat monitoring.
#
resource "azurerm_security_center_subscription_pricing" "defender_ai" {
  tier          = "Free"
  resource_type = "AI"
}

# =============================================================================
# BUDGET CONFIGURATION
# =============================================================================

variable "budget_monthly_amount" {
  description = "Monthly budget limit in EUR for Azure OpenAI/Cognitive Services spending. Set via TF_VAR_budget_monthly_amount. Defaults to 5 EUR intentionally low — set an appropriate limit before deploying to production."
  type        = number
  default     = 5
}

variable "budget_alert_emails" {
  description = "Comma-separated list of email addresses to receive budget alerts. Set via TF_VAR_budget_alert_emails."
  type        = string
  default     = ""

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "At least one budget alert email must be specified. Set TF_VAR_budget_alert_emails (comma-separated for multiple emails)."
  }
}

# =============================================================================
# CORE INFRASTRUCTURE
# =============================================================================

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_log_analytics_workspace" "la" {
  name                = "AzureLIT-POC-LA-2"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "cae" {
  name                       = "AzureLIT-POC-CAE"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.la.id
}

# =============================================================================
# LITELLM CONFIG (generated from model map)
# =============================================================================

locals {
  config_yaml = templatefile("${path.module}/config.yaml.tpl", {
    models       = var.models
    region_short = local.region_short
  })

  custom_auth_py    = file("${path.module}/custom_auth.py")
  usage_callback_py = file("${path.module}/usage_callback.py")

  # Flattened list of {env_key, secret_name, endpoint} per distinct region
  # Used to build dynamic Container App secrets + env vars
  distinct_regions = toset([for k, m in var.models : m.region])
}

# =============================================================================
# LITELLM PROXY CONTAINER APP
# =============================================================================

resource "azurerm_container_app" "ca" {
  name                         = "litellm-proxy"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  # LiteLLM config injected as secret
  secret {
    name  = "config-yaml"
    value = local.config_yaml
  }

  # Master key
  secret {
    name  = "litellm-master-key"
    value = var.litellm_master_key
  }

  # Client API keys — comma-separated, validated by custom_auth.py
  secret {
    name  = "api-keys"
    value = var.api_keys
  }

  # custom_auth.py source — copied to /app/custom_auth.py by container entrypoint
  secret {
    name  = "custom-auth-py"
    value = local.custom_auth_py
  }

  # usage_callback.py source — copied to /app/usage_callback.py by container entrypoint
  secret {
    name  = "usage-callback-py"
    value = local.usage_callback_py
  }

  # Log Analytics shared key
  secret {
    name  = "log-analytics-key"
    value = azurerm_log_analytics_workspace.la.primary_shared_key
  }

  # One API key secret per distinct region
  dynamic "secret" {
    for_each = local.distinct_regions
    content {
      name  = "azure-ai-key-${local.region_short[secret.value]}"
      value = local.account_keys[secret.value]
    }
  }

  template {
    min_replicas               = 0
    max_replicas               = 2
    cooldown_period_in_seconds = 600

    # Secret volume: all Container App secrets are mounted as files.
    # Only config-yaml and custom-auth-py are used; the rest are harmless extras.
    volume {
      name         = "secrets-volume"
      storage_type = "Secret"
    }

    # EmptyDir at /app: receives properly-named copies of config.yaml and custom_auth.py.
    # Necessary because secret names (config-yaml, custom-auth-py) are not valid
    # filenames for LiteLLM's --config path or Python's importlib.
    volume {
      name         = "config-volume"
      storage_type = "EmptyDir"
    }

    container {
      name   = "litellm"
      image  = "ghcr.io/berriai/litellm:main-v1.82.3"
      cpu    = 0.5
      memory = "1Gi"

      # Copy secrets to properly-named files in /app, then start LiteLLM.
      # Replaces the former busybox init container, eliminating that image pull
      # from the cold-start path.
      command = ["/bin/sh", "-c"]
      args    = ["cp /mnt/secrets/config-yaml /app/config.yaml && cp /mnt/secrets/custom-auth-py /app/custom_auth.py && cp /mnt/secrets/usage-callback-py /app/usage_callback.py && exec litellm --config /app/config.yaml --port 4000 --host 0.0.0.0"]

      env {
        name        = "LITELLM_MASTER_KEY"
        secret_name = "litellm-master-key"
      }

      env {
        name        = "API_KEYS"
        secret_name = "api-keys"
      }

      # Skip load_dotenv() filesystem scan on import
      env {
        name  = "LITELLM_MODE"
        value = "PRODUCTION"
      }

      # Suppress debug logging; ERROR-only reduces startup and runtime log I/O
      env {
        name  = "LITELLM_LOG"
        value = "ERROR"
      }

      # Shared API version for all Azure AI endpoints
      env {
        name  = "AZURE_AI_API_VERSION"
        value = "2024-10-21"
      }

      # Force a new revision when rendered config changes.
      env {
        name  = "LITELLM_CONFIG_SHA"
        value = sha256(local.config_yaml)
      }

      # Force a new revision when custom_auth.py or usage_callback.py change.
      env {
        name  = "CUSTOM_AUTH_SHA"
        value = sha256(local.custom_auth_py)
      }

      env {
        name  = "USAGE_CALLBACK_SHA"
        value = sha256(local.usage_callback_py)
      }

      # Log Analytics credentials for usage tracking
      env {
        name  = "LOG_ANALYTICS_CUSTOMER_ID"
        value = azurerm_log_analytics_workspace.la.workspace_id
      }

      env {
        name        = "LOG_ANALYTICS_KEY"
        secret_name = "log-analytics-key"
      }

      env {
        name  = "USAGE_LOG_TYPE"
        value = "LiteLLMUsage"
      }

      # One API_BASE + API_KEY env var per distinct region
      dynamic "env" {
        for_each = local.account_endpoints
        content {
          name  = "AZURE_AI_API_BASE_${upper(local.region_short[env.key])}"
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.distinct_regions
        content {
          name        = "AZURE_AI_API_KEY_${upper(local.region_short[env.value])}"
          secret_name = "azure-ai-key-${local.region_short[env.value]}"
        }
      }

      # Startup probe: prevents liveness from killing the container during LiteLLM
      # initialisation (model list loading, plugin imports, etc.).
      # 10s initial delay + up to 10 failures × 5s period = ~60s startup window.
      startup_probe {
        transport = "HTTP"
        path      = "/health/liveliness"
        port      = 4000

        initial_delay           = 10
        interval_seconds        = 5
        failure_count_threshold = 10
      }

      # Liveness probe: restarts the container if LiteLLM becomes unresponsive.
      liveness_probe {
        transport = "HTTP"
        path      = "/health/liveliness"
        port      = 4000

        initial_delay           = 0
        interval_seconds        = 10
        failure_count_threshold = 3
      }

      # Readiness probe: keeps the container out of the load balancer rotation
      # until LiteLLM is fully initialised and ready to handle requests.
      # /health/readiness is gated by custom_auth.py, which now bypasses auth
      # for all /health/* paths so the probe can reach it without a Bearer token.
      readiness_probe {
        transport = "HTTP"
        path      = "/health/readiness"
        port      = 4000

        interval_seconds        = 5
        failure_count_threshold = 3
        success_count_threshold = 1
      }

      volume_mounts {
        name = "secrets-volume"
        path = "/mnt/secrets"
      }

      volume_mounts {
        name = "config-volume"
        path = "/app"
      }
    }
  }

  ingress {
    external_enabled           = true
    target_port                = 4000
    allow_insecure_connections = false
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}
