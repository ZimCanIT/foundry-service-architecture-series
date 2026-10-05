variable "name" {
  description = "Globally unique name for the Linux web application."
  type        = string
}

variable "location" {
  description = "Azure region for the App Service plan and web application."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group containing the web application."
  type        = string
}

variable "resource_group_id" {
  description = "Resource ID of the resource group containing the App Service plan."
  type        = string
}

variable "service_plan_name" {
  description = "Name to use when this module creates an App Service plan."
  type        = string
  default     = null
}

variable "service_plan_resource_id" {
  description = "Optional ID of an existing shared App Service plan. When null, this module creates a plan with the Azure Verified Module."
  type        = string
  default     = null
}

variable "service_plan_sku_name" {
  description = "SKU for an App Service plan created by this module."
  type        = string
  default     = "B1"
}

variable "service_plan_worker_count" {
  description = "Worker count for an App Service plan created by this module."
  type        = number
  default     = 1
}

variable "service_plan_zone_balancing_enabled" {
  description = "Whether zone balancing is enabled for the App Service plan. Keep disabled for SKUs and regions without zone support."
  type        = bool
  default     = false
}

variable "application_stack" {
  description = "Optional Linux runtime stack configuration for the web application."
  type = object({
    dotnet_version      = optional(string)
    go_version          = optional(string)
    java_server         = optional(string)
    java_server_version = optional(string)
    java_version        = optional(string)
    node_version        = optional(string)
    php_version         = optional(string)
    python_version      = optional(string)
  })
  default = {}
}

variable "app_settings" {
  description = "Application settings. Sensitive values are redacted from normal Terraform output but remain in local state."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "identity_type" {
  description = "Managed identity type enabled on the web application."
  type        = string
  default     = "SystemAssigned"
}

variable "https_only" {
  description = "Whether the web application is restricted to HTTPS."
  type        = bool
  default     = true
}

variable "public_network_access_enabled" {
  description = "Whether the web application has a public endpoint."
  type        = bool
  default     = true
}

variable "always_on" {
  description = "Whether to keep the web application loaded on its App Service plan."
  type        = bool
  default     = true
}

variable "ftps_state" {
  description = "FTPS state for the web application."
  type        = string
  default     = "Disabled"
}

variable "http2_enabled" {
  description = "Whether HTTP/2 is enabled for the web application."
  type        = bool
  default     = true
}

variable "minimum_tls_version" {
  description = "Minimum TLS version accepted by the web application."
  type        = string
  default     = "1.2"
}

variable "authentication" {
  description = "Optional Microsoft Entra Easy Auth configuration."
  type = object({
    enabled                    = optional(bool, false)
    client_id                  = optional(string)
    tenant_id                  = optional(string)
    client_secret_setting_name = optional(string)
    allowed_audiences          = optional(list(string), [])
    unauthenticated_action     = optional(string, "RedirectToLoginPage")
  })
  default = {}

  validation {
    condition = !var.authentication.enabled || (
      var.authentication.client_id != null &&
      var.authentication.tenant_id != null &&
      var.authentication.client_secret_setting_name != null
    )
    error_message = "When Easy Auth is enabled, client_id, tenant_id and client_secret_setting_name are required."
  }
}

variable "log_analytics_workspace_id" {
  description = "Optional workspace ID for web application diagnostic logs."
  type        = string
  default     = null
}

variable "enable_diagnostics" {
  description = "Whether to configure App Service diagnostic categories for Log Analytics."
  type        = bool
  default     = true

  validation {
    condition     = !var.enable_diagnostics || var.log_analytics_workspace_id != null
    error_message = "A Log Analytics workspace ID is required when diagnostics are enabled."
  }
}

variable "application_log_level" {
  description = "File system application log threshold."
  type        = string
  default     = "Warning"
}

variable "http_log_retention_in_days" {
  description = "Number of days to retain file system HTTP logs."
  type        = number
  default     = 7
}

variable "http_log_retention_in_mb" {
  description = "Maximum file system HTTP log size in megabytes."
  type        = number
  default     = 35
}

variable "tags" {
  description = "Tags applied to the App Service plan and web application."
  type        = map(string)
  default     = {}
}
