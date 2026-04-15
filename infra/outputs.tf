output "container_app_fqdn" {
  description = "FQDN of the Azure Container App"
  value       = azurerm_container_app.ca.ingress[0].fqdn
}

output "container_app_url" {
  description = "Public HTTPS URL of the Azure Container App"
  value       = "https://${azurerm_container_app.ca.ingress[0].fqdn}"
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for usage tracking"
  value       = azurerm_log_analytics_workspace.la.workspace_id
}

output "usage_query_example" {
  description = "Example KQL query for usage data"
  value       = "LiteLLMUsage_CL | where TimeGenerated > ago(7d) | summarize sum(TokensIn_d), sum(TokensOut_d) by KeyHash_s"
}
