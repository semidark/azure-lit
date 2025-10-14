output "container_app_fqdn" {
  description = "FQDN of the Azure Container App"
  value       = azurerm_container_app.ca.ingress[0].fqdn
}

output "container_app_url" {
  description = "Public HTTPS URL of the Azure Container App"
  value       = "https://${azurerm_container_app.ca.ingress[0].fqdn}"
}
