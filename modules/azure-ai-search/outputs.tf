output "search_service_id" {
  description = "Resource ID of the Azure AI Search service."
  value       = azurerm_search_service.this.id
}

output "search_service_name" {
  description = "Name of the Azure AI Search service."
  value       = azurerm_search_service.this.name
}

output "search_service_endpoint" {
  description = "HTTPS endpoint of the Azure AI Search service."
  value       = "https://${azurerm_search_service.this.name}.search.windows.net"
}
