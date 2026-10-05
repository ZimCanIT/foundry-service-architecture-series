variable "name" {
  description = "Name and custom subdomain for the Microsoft Foundry account."
  type        = string
}

variable "location" {
  description = "Azure region shared by the Foundry account and optional project."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group containing the Foundry account."
  type        = string
}

variable "create_project" {
  description = "Whether to create a Foundry project under the account."
  type        = bool
  default     = false
}

variable "project_name" {
  description = "Name of the optional Foundry project."
  type        = string
  default     = "project"
}

variable "project_display_name" {
  description = "Display name of the optional Foundry project."
  type        = string
  default     = "Microsoft Foundry Project"
}

variable "project_description" {
  description = "Description of the optional Foundry project."
  type        = string
  default     = "Microsoft Foundry project for this workload."
}

variable "model_deployment" {
  description = "Optional model deployment to create on the Foundry account. Set to null to create no deployment."
  type = object({
    name                   = string
    model_name             = string
    model_version          = string
    sku_name               = string
    capacity               = number
    format                 = optional(string, "OpenAI")
    rai_policy_name        = optional(string, "Microsoft.DefaultV2")
    version_upgrade_option = optional(string, "NoAutoUpgrade")
  })
  default = null
}

variable "log_analytics_workspace_id" {
  description = "Destination workspace for Foundry account diagnostic logs."
  type        = string
}

variable "application_insights_connection_string" {
  description = "Application Insights connection string required by the Foundry project trace connection."
  type        = string
  sensitive   = true
}

variable "deployment_principal_id" {
  description = "Optional object ID of the deployment principal that creates project connections and agents."
  type        = string
  default     = null
}

variable "project_connections" {
  description = "Optional per-service connections to create in the Foundry project."
  type = object({
    application_insights = optional(object({
      resource_id = string
      location    = string
    }))
    bing_grounding = optional(object({
      resource_id = string
      endpoint    = string
    }))
    azure_ai_search = optional(object({
      resource_id     = string
      endpoint        = string
      location        = string
      connection_name = optional(string, "azure-ai-search")
    }))
  })
  default = {}

  validation {
    condition = var.create_project || (
      var.project_connections.application_insights == null &&
      var.project_connections.bing_grounding == null &&
      var.project_connections.azure_ai_search == null
    )
    error_message = "Project connections require create_project = true."
  }
}

variable "bing_grounding_key" {
  description = "Sensitive key for the Foundry project Bing Grounding connection."
  type        = string
  sensitive   = true
  default     = null
}

variable "tags" {
  description = "Tags applied to the Foundry account and project."
  type        = map(string)
  default     = {}
}
