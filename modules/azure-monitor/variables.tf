variable "log_analytics_workspace_name" {
  description = "CAF-compliant Log Analytics workspace name."
  type        = string
}

variable "application_insights_name" {
  description = "CAF-compliant Application Insights name."
  type        = string
}

variable "location" {
  description = "Azure region for monitoring resources."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group containing the monitoring resources."
  type        = string
}

variable "tags" {
  description = "Tags applied to monitoring resources."
  type        = map(string)
  default     = {}
}

variable "log_analytics_sku" {
  description = "Workspace pricing tier."
  type        = string
  default     = "PerGB2018"
}

variable "retention_in_days" {
  description = "Interactive retention for the workspace in days (30 to 730)."
  type        = number
  default     = 30

  validation {
    condition     = var.retention_in_days >= 30 && var.retention_in_days <= 730
    error_message = "retention_in_days must be between 30 and 730."
  }
}

variable "daily_quota_gb" {
  description = "Daily ingestion cap in GB; -1 removes the cap. A cap bounds the cost of the AzureDiagnostics and AzureMetrics tables that Foundry fills."
  type        = number
  default     = 10
}

variable "log_analytics_local_authentication_enabled" {
  description = "Whether the workspace accepts shared-key authentication. False keeps the environment keyless."
  type        = bool
  default     = false
}

variable "application_insights_type" {
  description = "Application Insights application type."
  type        = string
  default     = "web"
}

variable "application_insights_local_authentication_enabled" {
  description = "Whether Application Insights accepts instrumentation-key ingestion. False keeps the environment keyless; the AzAPI update mirrors the value."
  type        = bool
  default     = false
}

variable "sampling_percentage" {
  description = "Telemetry sampling percentage for Application Insights; null keeps the service default."
  type        = number
  default     = null
}

variable "ip_masking_enabled" {
  description = "Whether Application Insights masks client IP addresses as 0.0.0.0. Null keeps the provider default of true; set false only if the data classification allows real IPs."
  type        = bool
  default     = null
}

variable "application_insights_retention_in_days" {
  description = "Application Insights retention in days (30, 60, 90, 120, 180, 270, 365, 550 or 730). Null keeps the service default."
  type        = number
  default     = null

  validation {
    condition     = var.application_insights_retention_in_days == null || contains([30, 60, 90, 120, 180, 270, 365, 550, 730], coalesce(var.application_insights_retention_in_days, 30))
    error_message = "application_insights_retention_in_days must be one of 30, 60, 90, 120, 180, 270, 365, 550 or 730."
  }
}

variable "application_insights_daily_data_cap_in_gb" {
  description = "Daily data volume cap for Application Insights in GB. Null keeps the service default."
  type        = number
  default     = null
}

variable "internet_ingestion_enabled" {
  description = "Whether Application Insights accepts ingestion from the public internet."
  type        = bool
  default     = true
}

variable "internet_query_enabled" {
  description = "Whether Application Insights accepts queries from the public internet."
  type        = bool
  default     = true
}

variable "table_retention" {
  description = "Per-table retention overrides, keyed by table name such as AzureDiagnostics. total_retention_in_days adds archive retention beyond the interactive period."
  type = map(object({
    retention_in_days       = number
    total_retention_in_days = optional(number)
  }))
  default = {}
}

variable "workspace_role_assignments" {
  description = "Role assignments on the workspace, keyed by a stable label, for example Log Analytics Reader for reviewers."
  type = map(object({
    role_definition_name = string
    principal_id         = string
    principal_type       = string
    description          = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for r in values(var.workspace_role_assignments) : contains(["User", "Group", "ServicePrincipal"], r.principal_type)])
    error_message = "workspace_role_assignments principal_type must be User, Group or ServicePrincipal."
  }
}

variable "lock" {
  description = "Optional management lock on the workspace. kind is CanNotDelete or ReadOnly. Null creates no lock."
  type = object({
    kind = string
    name = optional(string)
  })
  default = null

  validation {
    condition     = var.lock == null || contains(["CanNotDelete", "ReadOnly"], try(var.lock.kind, ""))
    error_message = "lock.kind must be CanNotDelete or ReadOnly."
  }
}
