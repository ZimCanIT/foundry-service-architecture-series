variable "subscription_id" {
  description = "Azure subscription ID targeted by both providers."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be a UUID."
  }
}

variable "tenant_id" {
  description = "Microsoft Entra tenant ID used by both providers."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.tenant_id))
    error_message = "tenant_id must be a UUID."
  }
}

variable "workload_name" {
  description = "CAF workload identifier used in Azure resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.workload_name)) && length(var.workload_name) <= 30
    error_message = "workload_name must be lowercase alphanumeric words separated by single hyphens and no more than 30 characters."
  }
}

variable "business_unit" {
  description = "Business unit accountable for this workload."
  type        = string
}

variable "data_classification" {
  description = "Organization-approved data classification tag, such as Public, Internal, Confidential, or Restricted."
  type        = string
}

variable "criticality" {
  description = "Business impact classification used by operations and governance."
  type        = string
}

variable "service_level" {
  description = "Approved service-level target or tier for this workload."
  type        = string
}

variable "support_group" {
  description = "Group accountable for operational support of this workload."
  type        = string
}

variable "department" {
  description = "Department accountable for this workload."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the dedicated resource group for this proof of concept."
  type        = string

  validation {
    condition     = length(trimspace(var.resource_group_name)) > 0 && length(var.resource_group_name) <= 90
    error_message = "resource_group_name must be nonempty and no more than 90 characters."
  }
}

variable "location" {
  description = "Azure region for the Foundry account and monitoring resources."
  type        = string
}

variable "region_code" {
  description = "Short region code included in regional resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,5}$", var.region_code))
    error_message = "region_code must contain two to five lowercase letters or digits."
  }
}

variable "instance" {
  description = "Three-digit instance identifier for this deployment."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{3}$", var.instance))
    error_message = "instance must be exactly three digits."
  }
}

variable "environment" {
  description = "Environment label applied as an Azure resource tag."
  type        = string

  validation {
    condition     = contains(["dev", "test", "qa", "uat", "staging", "prod"], lower(var.environment))
    error_message = "environment must be one of dev, test, qa, uat, staging, or prod."
  }
}

variable "owner" {
  description = "Owner responsible for this environment's Azure resources."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "ops_team" {
  description = "Operations team responsible for this workload."
  type        = string
}

variable "project" {
  description = "Project associated with these Azure resources."
  type        = string
}

variable "model_deployment_name" {
  description = "Name for the Fireworks model deployment in Foundry."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", var.model_deployment_name))
    error_message = "model_deployment_name must be 1-64 characters and contain only letters, numbers, dots, underscores, or hyphens."
  }
}

variable "model_version" {
  description = "Approved exact DeepSeek V4.1 Flash model version from the Azure model catalog."
  type        = string
}

variable "model_capacity" {
  description = "Requested Global Standard throughput capacity in tokens per minute (TPM), subject to model quota."
  type        = number

  validation {
    condition     = var.model_capacity > 0 && var.model_capacity == floor(var.model_capacity)
    error_message = "model_capacity must be a positive whole number of tokens per minute."
  }
}
