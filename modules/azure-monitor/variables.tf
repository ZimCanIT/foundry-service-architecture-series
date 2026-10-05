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
