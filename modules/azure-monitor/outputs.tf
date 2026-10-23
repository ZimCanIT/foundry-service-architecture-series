output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.this.id
}

output "application_insights_id" {
  description = "Resource ID of the Application Insights component."
  value       = azurerm_application_insights.this.id
}

output "application_insights_connection_string" {
  description = "Connection string for Application Insights."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.this.name
}

output "log_analytics_workspace_customer_id" {
  description = "Workspace (customer) ID used by query APIs and az monitor log-analytics query."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "application_insights_name" {
  description = "Name of the Application Insights component."
  value       = azurerm_application_insights.this.name
}

output "application_insights_app_id" {
  description = "Application ID of the Application Insights component."
  value       = azurerm_application_insights.this.app_id
}

# Aliases matching the Azure Verified Modules output names.
output "resource_id" {
  description = "Resource ID of the Log Analytics workspace (alias of log_analytics_workspace_id)."
  value       = azurerm_log_analytics_workspace.this.id
}

output "name" {
  description = "Name of the Log Analytics workspace (alias of log_analytics_workspace_name)."
  value       = azurerm_log_analytics_workspace.this.name
}
