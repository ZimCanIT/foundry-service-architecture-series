variable "workload_name" {
  description = "CAF workload identifier used in Azure resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.workload_name)) && length(var.workload_name) <= 30
    error_message = "workload_name must be lowercase alphanumeric words separated by single hyphens and no more than 30 characters."
  }
}

variable "resource_group_name" {
  description = "Name of the dedicated resource group for this proof of concept."
  type        = string
}

variable "location" {
  description = "Azure region for the single-region proof of concept."
  type        = string
  default     = "swedencentral"
}

variable "region_code" {
  description = "Short region code included in regional resource names."
  type        = string
  default     = "sc"

  validation {
    condition     = can(regex("^[a-z0-9]{2,5}$", var.region_code))
    error_message = "region_code must contain two to five lowercase letters or digits."
  }
}

variable "instance" {
  description = "Three-digit instance identifier for this deployment."
  type        = string
  default     = "001"

  validation {
    condition     = can(regex("^[0-9]{3}$", var.instance))
    error_message = "instance must be exactly three digits."
  }
}

variable "environment" {
  description = "Environment label applied as an Azure resource tag."
  type        = string
  default     = "uat"
}

variable "easy_auth_client_id" {
  description = "Client ID of the dedicated single-tenant Microsoft Entra application used by App Service Easy Auth."
  type        = string
}

variable "easy_auth_client_secret" {
  description = "Client secret for the Easy Auth application registration. It is stored in local Terraform state and must remain private."
  type        = string
  sensitive   = true
}

variable "search_index_name" {
  description = "Synthetic text index created by the bootstrap script."
  type        = string
  default     = "foundry-series-1"
}

variable "agent_name" {
  description = "Named Foundry prompt agent configured by the bootstrap script."
  type        = string
  default     = "baseline-chatbot-agent"
}

variable "agent_version" {
  description = "Version of the named prompt agent; set by the bootstrap output before the final apply."
  type        = string
  default     = "pending"
}

variable "tags" {
  description = "Additional tags applied to resources in this environment."
  type        = map(string)
  default     = {}
}
