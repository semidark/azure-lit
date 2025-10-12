terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0.0"
    }
  }
}

provider "azurerm" {
  subscription_id = "b6548f5c-d425-4e5c-bfb2-296186a152ee"

  features {}
}

variable "location" {
  description = "The Azure region to deploy the resources in."
  default     = "Sweden Central"
}

variable "resource_group_name" {
  description = "The name of the resource group."
  default     = "AzureLIT-POC"
}

variable "ai_foundry_hub_name" {
  description = "The name of the AI Foundry Hub."
  default     = "AzureLIT-Hub"
}

variable "ai_foundry_project_name" {
  description = "The name of the AI Foundry Project."
  default     = "AzureLIT-Project"
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_storage_account" "sa" {
  name                     = "azurelitsapoc"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_key_vault" "kv" {
  name                = "AzureLIT-POC-KV"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
}

data "azurerm_client_config" "current" {}

resource "azurerm_ai_foundry" "hub" {
  name                = var.ai_foundry_hub_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  storage_account_id  = azurerm_storage_account.sa.id
  key_vault_id        = azurerm_key_vault.kv.id

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_ai_foundry_project" "project" {
  name               = var.ai_foundry_project_name
  ai_services_hub_id = azurerm_ai_foundry.hub.id
  location           = azurerm_resource_group.rg.location
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

resource "azurerm_container_app" "ca" {
  name                         = "litellm-proxy"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  secret {
    name  = "config-yaml"
    value = file("${path.module}/config.yaml")
  }

  template {
    container {
      name   = "litellm"
      image  = "ghcr.io/berriai/litellm:main-latest"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "LITELLM_MASTER_KEY"
        value = "your-master-key" # Replace with a secure key
      }

      volume_mounts {
        name = "config-volume"
        path = "/app/config.yaml"
      }
    }

    volume {
      name         = "config-volume"
      storage_type = "Secret"
      storage_name = "config-yaml"
    }
  }

  ingress {
    external_enabled = true
    target_port      = 4000
    traffic_weight {
      percentage = 100
      latest_revision = true
    }
  }
}
