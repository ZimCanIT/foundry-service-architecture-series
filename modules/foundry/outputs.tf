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

# resource_id, name and system_assigned_mi_principal_id use the output names of the AVM cognitive services account module,
# so roots written against it can read the same outputs. The other outputs below are additions of this module.
output "resource_id" {
  description = "Resource ID of the Foundry account (alias of account_id)."
  value       = azurerm_cognitive_account.this.id
}

output "name" {
  description = "Name of the Foundry account (alias of account_name)."
  value       = azurerm_cognitive_account.this.name
}

output "system_assigned_mi_principal_id" {
  description = "Object ID of the system-assigned identity of the account (alias of account_identity_principal_id), or null when the account has only user-assigned identities."
  value       = azurerm_cognitive_account.this.identity[0].principal_id == "" ? null : azurerm_cognitive_account.this.identity[0].principal_id
}

output "project_resource_id" {
  description = "Resource ID of the optional project (alias of project_id)."
  value       = try(azurerm_cognitive_account_project.this[0].id, null)
}

output "diagnostic_setting_id" {
  description = "Resource ID of the account diagnostic setting."
  value       = azurerm_monitor_diagnostic_setting.account.id
}

output "role_assignment_ids" {
  description = "Resource IDs of the generic account role assignments, keyed by label."
  value       = { for k, r in azurerm_role_assignment.account : k => r.id }
}

output "model_deployment_metadata" {
  description = "Name, model, version, SKU, capacity and upgrade policy of the optional model deployment, or null when no deployment is created."
  value = var.model_deployment == null ? null : {
    id                     = azurerm_cognitive_deployment.model[0].id
    name                   = var.model_deployment.name
    format                 = var.model_deployment.format
    model_name             = var.model_deployment.model_name
    model_version          = var.model_deployment.model_version
    sku_name               = var.model_deployment.sku_name
    capacity               = var.model_deployment.capacity
    version_upgrade_option = var.model_deployment.version_upgrade_option
    rai_policy_name        = var.model_deployment.rai_policy_name
  }
}
