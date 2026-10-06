output "subscription_id" {
  description = "Subscription selected by the active Azure CLI context."
  value       = var.subscription_id
}

output "resource_group_name" {
  description = "Resource group containing this Fireworks on Foundry environment."
  value       = module.resource_group.name
}

output "foundry_account_name" {
  description = "Microsoft Foundry account name."
  value       = module.foundry.account_name
}

output "foundry_account_endpoint" {
  description = "Endpoint of the Microsoft Foundry account."
  value       = module.foundry.account_endpoint
}

output "foundry_project_id" {
  description = "Resource ID of the Foundry project."
  value       = module.foundry.project_id
}

output "fireworks_feature_registration_id" {
  description = "Subscription-scoped Fireworks.EnableDeploy registration resource ID."
  value       = data.azapi_resource.fireworks_feature_registration.id
}

output "fireworks_feature_registration_state" {
  description = "Current subscription-scoped state of Fireworks.EnableDeploy."
  value       = try(data.azapi_resource.fireworks_feature_registration.output.properties.state, "NotFound")
}

output "fireworks_model_deployment_id" {
  description = "Resource ID of the Fireworks DeepSeek deployment."
  value       = azapi_resource.fireworks_model_deployment.id
}

output "fireworks_model_deployment_name" {
  description = "Foundry deployment name for DeepSeek V4.1 Flash."
  value       = azapi_resource.fireworks_model_deployment.name
}

output "fireworks_model_version" {
  description = "Pinned DeepSeek V4.1 Flash model version deployed in Foundry."
  value       = var.model_version
}
