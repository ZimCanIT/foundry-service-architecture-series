output "subscription_id" {
  description = "Subscription that holds this environment."
  value       = var.subscription_id
}

output "resource_group_name" {
  description = "Resource group created by this environment."
  value       = azurerm_resource_group.this.name
}

output "foundry_account_name" {
  description = "Foundry account name, which is also its custom subdomain."
  value       = local.foundry.account_name
}

output "foundry_account_id" {
  description = "Resource ID of the Foundry account."
  value       = local.foundry.account_id
}

output "foundry_account_endpoint" {
  description = "Endpoint of the Foundry account."
  value       = local.foundry.account_endpoint
}

output "foundry_project_id" {
  description = "Resource ID of the Foundry project, used as the deployment source."
  value       = local.foundry.project_id
}

output "foundry_project_name" {
  description = "Name of the Foundry project that holds the registered adapter."
  value       = local.foundry.project_name
}

output "foundry_project_endpoint" {
  description = "Project endpoint passed to azd ai models create as --project-endpoint."
  value       = local.foundry.project_endpoint
}

output "fireworks_feature_state" {
  description = "State of the subscription feature Fireworks.EnableDeploy."
  value       = local.fireworks_feature_state
}

output "byow_deployment_names" {
  description = "Deployment names keyed like adapters; the name is the model value in inference calls."
  value       = { for key, deployment in azapi_resource.byow_deployment : key => deployment.name }
}

output "byow_deployment_ids" {
  description = "Deployment resource IDs keyed like adapters."
  value       = { for key, deployment in azapi_resource.byow_deployment : key => deployment.id }
}

output "ptu_total" {
  description = "Total Global Provisioned capacity the adapters request, for the approver's review."
  value       = local.ptu_total
}

output "key_vault_name" {
  description = "Name of the optional Key Vault for the Fireworks key, or null when it is off."
  value       = local.key_vault_name
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace."
  value       = module.azure_monitor.log_analytics_workspace_id
}

output "log_analytics_workspace_customer_id" {
  description = "Workspace (customer) ID that read_logs.sh queries."
  value       = module.azure_monitor.log_analytics_workspace_customer_id
}

output "budget_id" {
  description = "Resource ID of the resource group budget."
  value       = azurerm_consumption_budget_resource_group.this.id
}

output "action_group_id" {
  description = "Resource ID of the action group that receives budget alerts."
  value       = azurerm_monitor_action_group.this.id
}
