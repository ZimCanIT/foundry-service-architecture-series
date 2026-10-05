variable "name" {
  description = "CAF-compliant Azure AI Search service name."
  type        = string
}

variable "location" {
  description = "Azure region for the Search service."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group containing the Search service."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Destination workspace for Search diagnostics."
  type        = string
}

variable "deployment_principal_id" {
  description = "Object ID of the CLI deployment service principal used to create the Search index and load demo documents."
  type        = string
}

variable "tags" {
  description = "Tags applied to the Search service."
  type        = map(string)
  default     = {}
}
