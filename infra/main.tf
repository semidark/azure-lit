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

  # One API key secret per distinct region
  dynamic "secret" {
    for_each = local.distinct_regions
    content {
      name  = "azure-ai-key-${local.region_short[secret.value]}"
      value = local.account_keys[secret.value]
    }
  }

  template {
    volume {
      name         = "config-volume"
      storage_type = "EmptyDir"
    }

    # TODO: Remove init container (cold start overhead)
    init_container {
      name   = "init-config"
      image  = "busybox:latest"
      cpu    = 0.5
      memory = "1.0Gi"

      command = ["/bin/sh", "-c"]
      args    = ["printf \"%s\" \"$CONF_YAML\" > /mnt/config/config.yaml"]

      env {
        name        = "CONF_YAML"
        secret_name = "config-yaml"
      }

      volume_mounts {
        name = "config-volume"
        path = "/mnt/config"
      }
    }

    container {
      name   = "litellm"
      image  = "ghcr.io/berriai/litellm:main-stable"
      cpu    = 0.5
      memory = "1.0Gi"

      command = ["litellm"]
      args    = ["--config", "/app/config.yaml", "--port", "4000", "--host", "0.0.0.0", "--detailed_debug"]

      env {
        name        = "LITELLM_MASTER_KEY"
        secret_name = "litellm-master-key"
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
