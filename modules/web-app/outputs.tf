output "web_app_id" {
  description = "Resource ID of the web application."
  value       = azurerm_linux_web_app.this.id
}

output "web_app_name" {
  description = "Name of the web application."
  value       = azurerm_linux_web_app.this.name
}

output "web_app_hostname" {
  description = "Default hostname of the web application."
  value       = azurerm_linux_web_app.this.default_hostname
}

output "web_app_url" {
  description = "HTTPS endpoint of the web application."
  value       = "https://${azurerm_linux_web_app.this.default_hostname}"
}

output "identity_principal_id" {
  description = "Principal ID of the web application's system-assigned managed identity."
  value       = try(azurerm_linux_web_app.this.identity[0].principal_id, null)
}

output "service_plan_id" {
  description = "Resource ID of the App Service plan used by the web application."
  value       = local.service_plan_id
}
