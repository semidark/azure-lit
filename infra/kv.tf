# Key Vault secret for Azure AI Foundry project API key
# For PoC: manually set this secret in Key Vault prior to terraform apply

resource "azurerm_key_vault_secret" "foundry_api_key" {
  depends_on   = [azurerm_key_vault_access_policy.current]
  name         = "foundry-project-api-key"
  value        = var.foundry_api_key
  key_vault_id = azurerm_key_vault.kv.id
}
