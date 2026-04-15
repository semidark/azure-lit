# =============================================================================
# MODEL MAP
# =============================================================================
# Add models here. Terraform handles account creation, deployment, and
# LiteLLM config wiring automatically.
#
# Fields:
#   format         - "OpenAI" | "OpenAI-OSS"
#   version        - pinned model version string
#   sku            - "DataZoneStandard" | "GlobalStandard" | "ProvisionedManaged"
#   capacity       - TPM capacity units (varies by model/sku)
#   region         - Azure region. Use var.location for primary. Other regions
#                    trigger a new Cognitive Account in that region automatically.
#   project        - true = deploy into Foundry project (required by some models
#                    e.g. gpt-oss-120b). false = deploy directly on account.
#   responses_only - true = model only supports the Responses API (e.g. codex
#                    models). LiteLLM config uses azure/responses/ prefix and
#                    api_version=preview. false = standard chat completions.
# =============================================================================

variable "models" {
  description = "Map of model deployments. Key becomes the deployment name and LiteLLM model alias."
  type = map(object({
    format                = string
    version               = string
    sku                   = string
    capacity              = number
    region                = string
    project               = optional(bool, false)
    responses_only        = optional(bool, false)
    base_model            = optional(string)
    input_cost_per_token  = optional(number)
    output_cost_per_token = optional(number)
  }))

  default = {
    "gpt-4.1" = {
      format     = "OpenAI"
      version    = "2025-04-14"
      sku        = "DataZoneStandard"
      capacity   = 50
      region     = "germanywestcentral"
      project    = false
      base_model = "azure/gpt-4.1"
    }
    "gpt-oss-120b" = {
      format     = "OpenAI-OSS"
      version    = "1"
      sku        = "GlobalStandard"
      capacity   = 10
      region     = "germanywestcentral"
      project    = false
      base_model = "azure_ai/gpt-oss-120b"
    }
    "Kimi-K2.5" = {
      format     = "MoonshotAI"
      version    = "1"
      sku        = "GlobalStandard"
      capacity   = 100 # quota limit on sandbox subscription
      region     = "germanywestcentral"
      project    = false
      base_model = "azure_ai/kimi-k2.5"
    }
    "grok-4-20-reasoning" = {
      format     = "xAI"
      version    = "1"
      sku        = "GlobalStandard"
      capacity   = 1
      region     = "germanywestcentral"
      project    = false
      base_model = "azure_ai/grok-4"
    }
    "gpt-5.4" = {
      format     = "OpenAI"
      version    = "2026-03-05"
      sku        = "GlobalStandard"
      capacity   = 1000
      region     = "germanywestcentral"
      project    = false
      base_model = "azure/gpt-5.4"
    }
    "gpt-5.3-codex" = {
      format         = "OpenAI"
      version        = "2026-02-24"
      sku            = "GlobalStandard"
      capacity       = 1000
      region         = "swedencentral"
      project        = false
      responses_only = true
      base_model     = "azure/gpt-5.3-codex"
    }
    "gpt-5.1-codex" = {
      format         = "OpenAI"
      version        = "2025-11-13"
      sku            = "GlobalStandard"
      capacity       = 10
      region         = "germanywestcentral"
      project        = false
      responses_only = true
      base_model     = "azure/gpt-5.1-codex"
    }
  }
}

# =============================================================================
# REGION SHORT NAMES
# Add an entry here when targeting a new region.
# =============================================================================

locals {
  region_short = {
    "germanywestcentral" = "gwc"
    "eastus"             = "eus"
    "eastus2"            = "eus2"
    "westus"             = "wus"
    "westus2"            = "wus2"
    "swedencentral"      = "swc"
    "northeurope"        = "neu"
    "westeurope"         = "weu"
    "centralus"          = "cus"
  }

  # Normalize var.location to lowercase-no-spaces to match model map region keys
  primary_region = lower(replace(var.location, " ", ""))

  # Distinct regions that need a secondary Cognitive Account
  remote_regions = toset([
    for k, m in var.models : m.region
    if m.region != local.primary_region
  ])

  # region -> account resource ID
  account_ids = merge(
    { (local.primary_region) = azurerm_cognitive_account.openai.id },
    { for r, acct in azurerm_cognitive_account.regional : r => acct.id }
  )

  # region -> project resource ID
  project_ids = merge(
    { (local.primary_region) = azurerm_cognitive_account_project.primary.id },
    { for r, proj in azurerm_cognitive_account_project.regional : r => proj.id }
  )

  # region -> endpoint URL
  account_endpoints = merge(
    { (local.primary_region) = azurerm_cognitive_account.openai.endpoint },
    { for r, acct in azurerm_cognitive_account.regional : r => acct.endpoint }
  )

  # region -> primary access key (sensitive)
  account_keys = merge(
    { (local.primary_region) = azurerm_cognitive_account.openai.primary_access_key },
    { for r, acct in azurerm_cognitive_account.regional : r => acct.primary_access_key }
  )

  # Deployment buckets
  primary_account_models = {
    for k, m in var.models : k => m
    if m.region == local.primary_region && !m.project
  }
  primary_project_models = {
    for k, m in var.models : k => m
    if m.region == local.primary_region && m.project
  }
  remote_account_models = {
    for k, m in var.models : k => m
    if m.region != local.primary_region && !m.project
  }
  remote_project_models = {
    for k, m in var.models : k => m
    if m.region != local.primary_region && m.project
  }
}

# =============================================================================
# PRIMARY COGNITIVE ACCOUNT (Germany West Central)
# =============================================================================

resource "azurerm_cognitive_account" "openai" {
  name                  = "azurelit-openai"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = "azurelit-openai"

  identity { type = "SystemAssigned" }

  project_management_enabled         = true
  public_network_access_enabled      = true
  local_auth_enabled                 = true
  outbound_network_access_restricted = false
}

resource "azurerm_cognitive_account_project" "primary" {
  name                 = "AzureLIT-Project"
  cognitive_account_id = azurerm_cognitive_account.openai.id
  location             = azurerm_resource_group.rg.location

  identity { type = "SystemAssigned" }
}

# =============================================================================
# REGIONAL COGNITIVE ACCOUNTS (auto-created per non-primary region in model map)
# =============================================================================

resource "azurerm_cognitive_account" "regional" {
  for_each = local.remote_regions

  name                  = "azurelit-${local.region_short[each.key]}"
  location              = each.key
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = "azurelit-${local.region_short[each.key]}"

  identity { type = "SystemAssigned" }

  project_management_enabled         = true
  public_network_access_enabled      = true
  local_auth_enabled                 = true
  outbound_network_access_restricted = false
}

resource "azurerm_cognitive_account_project" "regional" {
  for_each = local.remote_regions

  name                 = "AzureLIT-Project"
  cognitive_account_id = azurerm_cognitive_account.regional[each.key].id
  location             = each.key

  identity { type = "SystemAssigned" }
}

# =============================================================================
# MODEL DEPLOYMENTS
# =============================================================================

# Primary account, account-scoped
resource "azurerm_cognitive_deployment" "primary_account" {
  for_each = local.primary_account_models

  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.openai.id
  rai_policy_name      = azurerm_cognitive_account_rai_policy.permissive.name

  model {
    format  = each.value.format
    name    = each.key
    version = each.value.version
  }

  sku {
    name     = each.value.sku
    capacity = each.value.capacity
  }
}

# Primary account, project-scoped (requires azapi — azurerm_cognitive_deployment
# does not accept project IDs)
resource "azapi_resource" "primary_project" {
  for_each = local.primary_project_models

  type                      = "Microsoft.CognitiveServices/accounts/projects/deployments@2025-06-01"
  name                      = each.key
  parent_id                 = azurerm_cognitive_account_project.primary.id
  schema_validation_enabled = false

  body = {
    sku = {
      name     = each.value.sku
      capacity = each.value.capacity
    }
    properties = {
      model = {
        format  = each.value.format
        name    = each.key
        version = each.value.version
      }
    }
  }
}

# Remote accounts, account-scoped
resource "azurerm_cognitive_deployment" "remote_account" {
  for_each = local.remote_account_models

  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.regional[each.value.region].id
  rai_policy_name      = azurerm_cognitive_account_rai_policy.permissive_regional[each.value.region].name

  model {
    format  = each.value.format
    name    = each.key
    version = each.value.version
  }

  sku {
    name     = each.value.sku
    capacity = each.value.capacity
  }
}

# Remote accounts, project-scoped
resource "azapi_resource" "remote_project" {
  for_each = local.remote_project_models

  type                      = "Microsoft.CognitiveServices/accounts/projects/deployments@2025-06-01"
  name                      = each.key
  parent_id                 = azurerm_cognitive_account_project.regional[each.value.region].id
  schema_validation_enabled = false

  body = {
    sku = {
      name     = each.value.sku
      capacity = each.value.capacity
    }
    properties = {
      model = {
        format  = each.value.format
        name    = each.key
        version = each.value.version
      }
    }
  }
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "openai_endpoint" {
  value = azurerm_cognitive_account.openai.endpoint
}

output "regional_endpoints" {
  description = "Endpoints for all regional Cognitive Accounts"
  value = {
    for r, acct in azurerm_cognitive_account.regional : r => acct.endpoint
  }
}
