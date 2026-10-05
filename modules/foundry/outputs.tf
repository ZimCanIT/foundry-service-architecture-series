output "account_id" {
  description = "Resource ID of the Microsoft Foundry account."
  value       = azurerm_cognitive_account.this.id
}

output "account_name" {
  description = "Name of the Microsoft Foundry account."
  value       = azurerm_cognitive_account.this.name
}

output "account_endpoint" {
  description = "Endpoint of the Microsoft Foundry account."
  value       = azurerm_cognitive_account.this.endpoint
}

output "account_identity_principal_id" {
  description = "System-assigned identity object ID of the Foundry account."
  value       = azurerm_cognitive_account.this.identity[0].principal_id
}

output "project_id" {
  description = "Resource ID of the optional Foundry project, or null when no project is created."
  value       = try(azurerm_cognitive_account_project.this[0].id, null)
}

output "project_name" {
  description = "Name of the optional Foundry project, or null when no project is created."
  value       = try(azurerm_cognitive_account_project.this[0].name, null)
}

output "project_endpoint" {
  description = "Foundry API endpoint for the optional project, or null when no project is created."
  value       = try(azurerm_cognitive_account_project.this[0].endpoints["AI Foundry API"], null)
}

output "project_identity_principal_id" {
  description = "System-assigned identity object ID of the optional project."
  value       = try(azurerm_cognitive_account_project.this[0].identity[0].principal_id, null)
}

output "model_deployment_name" {
  description = "Name of the optional model deployment, or null when no deployment is created."
  value       = try(azurerm_cognitive_deployment.model[0].name, null)
}

output "azure_ai_search_connection_id" {
  description = "Resource ID of the optional Azure AI Search project connection."
  value       = try(azapi_resource.azure_ai_search_connection[0].id, null)
}

output "bing_connection_id" {
  description = "Resource ID of the optional Bing Grounding project connection."
  value       = try(azapi_resource.bing_connection[0].id, null)
}

output "application_insights_connection_id" {
  description = "Resource ID of the optional Application Insights project connection."
  value       = try(azapi_resource.application_insights_connection[0].id, null)
}
