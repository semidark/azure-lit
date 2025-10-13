resource "azurerm_cognitive_account" "openai" {
  name                = "azurelit-openai"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  kind                = "OpenAI"
  sku_name            = "S0"

  identity { type = "SystemAssigned" }

  public_network_access_enabled       = true
  local_auth_enabled                  = true
  outbound_network_access_restricted  = false
}

resource "azurerm_cognitive_deployment" "gpt41" {
  name                 = "gpt-4.1"
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4.1"
    version = "2025-04-14"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 1
  }
}

# Expose endpoint + key via outputs for wiring
output "openai_endpoint" {
  value = azurerm_cognitive_account.openai.endpoint
}

output "openai_primary_key" {
  value     = azurerm_cognitive_account.openai.primary_access_key
  sensitive = true
}
