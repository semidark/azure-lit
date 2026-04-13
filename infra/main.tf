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
# CORE INFRASTRUCTURE
# =============================================================================

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_log_analytics_workspace" "la" {
  name                = "AzureLIT-POC-LA"
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

  custom_auth_py = file("${path.module}/custom_auth.py")

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

  # One API key secret per distinct region
  dynamic "secret" {
    for_each = local.distinct_regions
    content {
      name  = "azure-ai-key-${local.region_short[secret.value]}"
      value = local.account_keys[secret.value]
    }
  }

  template {
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
      image  = "ghcr.io/berriai/litellm:main-stable"
      cpu    = 0.5
      memory = "1.0Gi"

      # Copy secrets to properly-named files in /app, then start LiteLLM.
      # Replaces the former busybox init container, eliminating that image pull
      # from the cold-start path.
      command = ["/bin/sh", "-c"]
      args    = ["cp /mnt/secrets/config-yaml /app/config.yaml && cp /mnt/secrets/custom-auth-py /app/custom_auth.py && exec litellm --config /app/config.yaml --port 4000 --host 0.0.0.0"]

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
    external_enabled = true
    target_port      = 4000
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}
