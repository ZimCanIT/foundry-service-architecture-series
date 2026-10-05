output "resource_id" {
  description = "Resource ID of the Bing Grounding account."
  value       = azapi_resource.this.id
}

output "endpoint" {
  description = "Bing Grounding endpoint returned by Azure Resource Manager."
  value       = azapi_resource.this.output.properties.endpoint
}

output "key" {
  description = "Bing Grounding account key for its Foundry project connection."
  value       = data.azapi_resource_action.keys.sensitive_output.key1
  sensitive   = true
}
