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

variable "managed_by" {
  description = "Tool that manages these resources, recorded in the ManagedBy tag."
  type        = string
}

variable "adapters" {
  description = "Preview: importing LoRA adapters to Fireworks on Foundry is a preview feature under the Supplemental Terms of Use for Microsoft Azure Previews. One Global Provisioned deployment per entry, keyed by deployment name. Leave empty for phase 1; add an entry only after the model shows as Registered in the Foundry project."
  type = map(object({
    model_name    = string
    model_version = optional(string, "1")
    ptu_capacity  = number
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for name in keys(var.adapters) : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", name))])
    error_message = "Each adapters key is a deployment name: 1 to 64 letters, digits, dots, underscores or hyphens, starting with a letter or digit."
  }

  validation {
    condition     = alltrue([for adapter in values(var.adapters) : adapter.ptu_capacity > 0 && floor(adapter.ptu_capacity) == adapter.ptu_capacity])
    error_message = "Each adapters ptu_capacity must be a positive whole number."
  }

  validation {
    condition     = alltrue([for adapter in values(var.adapters) : length(trimspace(adapter.model_name)) > 0 && length(trimspace(adapter.model_version)) > 0])
    error_message = "Each adapters entry needs a model_name and a model_version."
  }
}

variable "ptu_gate" {
  description = "Approval for Global Provisioned capacity, which bills hourly from creation to deletion. approved and approver are set after the approver has read the saved phase 2 plan; cap is the most PTUs all adapters may use together; minimum and increment are copied from the custom model's deploy dialog in the Foundry portal."
  type = object({
    approved  = optional(bool, false)
    approver  = optional(string, "")
    cap       = optional(number, 0)
    minimum   = optional(number)
    increment = optional(number)
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.ptu_gate.cap >= 0 && floor(var.ptu_gate.cap) == var.ptu_gate.cap
    error_message = "ptu_gate.cap must be a whole number of at least 0."
  }

  validation {
    condition = alltrue([
      for value in [var.ptu_gate.minimum, var.ptu_gate.increment] :
      value == null ? true : value > 0 && floor(value) == value
    ])
    error_message = "ptu_gate.minimum and ptu_gate.increment must be null or positive whole numbers."
  }
}

variable "budget" {
  description = "Monthly budget on the resource group, in the billing currency, with email alerts. Set amount from the hourly PTU figure in the portal times the planned hours, plus the small fixed resources. Budgets are evaluated daily, so the PTU gate is the control and the budget is the backstop."
  type = object({
    amount                = number
    start_date            = string
    end_date              = optional(string)
    actual_thresholds     = optional(set(number), [80, 100])
    forecasted_thresholds = optional(set(number), [100])
    alert_email_addresses = set(string)
  })

  validation {
    condition     = var.budget.amount > 0
    error_message = "budget.amount must be greater than 0."
  }

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-01T00:00:00Z$", var.budget.start_date))
    error_message = "budget.start_date must be the first day of a month, such as 2026-11-01T00:00:00Z."
  }

  validation {
    condition     = alltrue([for t in setunion(var.budget.actual_thresholds, var.budget.forecasted_thresholds) : t >= 1 && t <= 1000])
    error_message = "Budget thresholds must be between 1 and 1000 per cent."
  }

  validation {
    condition     = length(var.budget.actual_thresholds) + length(var.budget.forecasted_thresholds) <= 5
    error_message = "A budget has at most five notifications across actual and forecasted thresholds."
  }

  validation {
    condition     = length(var.budget.alert_email_addresses) > 0 && alltrue([for a in var.budget.alert_email_addresses : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", a))])
    error_message = "budget.alert_email_addresses needs at least one valid email address."
  }
}

variable "inference_principals" {
  description = "Identities that call the deployments keylessly, keyed by a stable label. role is Foundry User (named by the Foundry RBAC page) or Cognitive Services User (named by the Foundry Models keyless page)."
  type = map(object({
    principal_id   = string
    principal_type = string
    role           = optional(string, "Foundry User")
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for p in values(var.inference_principals) : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", p.principal_id))])
    error_message = "Each inference_principals principal_id must be an object ID (UUID)."
  }

  validation {
    condition     = alltrue([for p in values(var.inference_principals) : contains(["User", "Group", "ServicePrincipal"], p.principal_type)])
    error_message = "Each inference_principals principal_type must be User, Group or ServicePrincipal."
  }

  validation {
    condition     = alltrue([for p in values(var.inference_principals) : contains(["Foundry User", "Cognitive Services User"], p.role)])
    error_message = "Each inference_principals role must be Foundry User or Cognitive Services User."
  }
}

variable "key_vault" {
  description = "Optional Key Vault for the Fireworks API key. Off by default, because firectl signin needs no key. Terraform never writes the secret; set_fireworks_secret.py does. Turn purge protection on for anything beyond a demo that is destroyed after each rehearsal."
  type = object({
    enabled                    = optional(bool, false)
    name_stem                  = optional(string, "byow")
    soft_delete_retention_days = optional(number, 7)
    purge_protection_enabled   = optional(bool, false)
  })
  default  = {}
  nullable = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.key_vault.name_stem))
    error_message = "key_vault.name_stem must be 2 to 8 lowercase letters or digits, starting with a letter."
  }

  validation {
    condition     = var.key_vault.soft_delete_retention_days >= 7 && var.key_vault.soft_delete_retention_days <= 90
    error_message = "key_vault.soft_delete_retention_days must be between 7 and 90."
  }
}
