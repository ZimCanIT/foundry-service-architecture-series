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

  validation {
    condition     = var.model_deployment == null ? true : var.model_deployment.capacity > 0 && floor(var.model_deployment.capacity) == var.model_deployment.capacity
    error_message = "model_deployment.capacity must be a positive whole number."
  }

  validation {
    condition     = var.model_deployment == null ? true : contains(["NoAutoUpgrade", "OnceNewDefaultVersionAvailable", "OnceCurrentVersionExpired"], var.model_deployment.version_upgrade_option)
    error_message = "model_deployment.version_upgrade_option must be NoAutoUpgrade, OnceNewDefaultVersionAvailable or OnceCurrentVersionExpired."
  }

  validation {
    condition     = var.model_deployment == null ? true : var.model_deployment.version_upgrade_option != "NoAutoUpgrade" || length(trimspace(var.model_deployment.model_version)) > 0
    error_message = "model_deployment.model_version must be set when version_upgrade_option is NoAutoUpgrade, so the deployment stays on the version that was reviewed."
  }

  validation {
    condition     = var.model_deployment == null ? true : can(regex("^[A-Za-z0-9]+$", var.model_deployment.sku_name))
    error_message = "model_deployment.sku_name must be a SKU name such as GlobalStandard or ProvisionedManaged."
  }
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

variable "diagnostic_log_categories" {
  description = "Log categories sent from the account to the workspace. Audit and RequestResponse are the useful ones; AzureOpenAIRequestUsage and ManagedNetworkEvent carry an export charge, and Trace is emitted only by custom question answering. All categories land in the shared AzureDiagnostics table."
  type        = set(string)
  default     = ["Audit", "RequestResponse", "AzureOpenAIRequestUsage", "Trace"]

  validation {
    condition     = alltrue([for c in var.diagnostic_log_categories : contains(["Audit", "RequestResponse", "AzureOpenAIRequestUsage", "Trace", "ManagedNetworkEvent"], c)])
    error_message = "diagnostic_log_categories may contain only Audit, RequestResponse, AzureOpenAIRequestUsage, Trace and ManagedNetworkEvent."
  }
}

variable "diagnostic_metric_categories" {
  description = "Metric categories sent by the same diagnostic setting. Empty by default because roots that already route AllMetrics through a separate setting cannot send the same category to the same workspace twice."
  type        = set(string)
  default     = []
}

variable "project_diagnostics_enabled" {
  description = "Creates a diagnostic setting on the project (Audit and Trace logs plus AllMetrics). Requires create_project."
  type        = bool
  default     = false
}

variable "project_diagnostic_log_categories" {
  description = "Log categories for the project diagnostic setting."
  type        = set(string)
  default     = ["Audit", "Trace"]

  validation {
    condition     = alltrue([for c in var.project_diagnostic_log_categories : contains(["Audit", "Trace"], c)])
    error_message = "project_diagnostic_log_categories may contain only Audit and Trace."
  }
}

variable "role_assignments" {
  description = "Additional role assignments on the Foundry account, keyed by a stable label. Use built-in role names such as Foundry User or Foundry Owner; conditions use ABAC condition syntax with condition_version 2.0."
  type = map(object({
    role_definition_name = string
    principal_id         = string
    principal_type       = string
    description          = optional(string)
    condition            = optional(string)
    condition_version    = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for r in values(var.role_assignments) : contains(["User", "Group", "ServicePrincipal"], r.principal_type)])
    error_message = "role_assignments principal_type must be User, Group or ServicePrincipal."
  }

  validation {
    condition     = alltrue([for r in values(var.role_assignments) : (r.condition == null) == (r.condition_version == null)])
    error_message = "role_assignments condition and condition_version must be set together."
  }
}

variable "lock" {
  description = "Optional management lock on the account. kind is CanNotDelete or ReadOnly. Null creates no lock."
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

variable "security_profile" {
  description = "baseline keeps the current behaviour. production adds plan-time checks on the account: public access off or a Deny default action, at least one diagnostic log category, and no Owner, Contributor or User Access Administrator in role_assignments. Local key authentication is off in both profiles."
  type        = string
  default     = "baseline"

  validation {
    condition     = contains(["baseline", "production"], var.security_profile)
    error_message = "security_profile must be baseline or production."
  }
}

variable "public_network_access_enabled" {
  description = "Whether the account accepts traffic from public networks. The baseline keeps this on; private networking belongs in its own root."
  type        = bool
  default     = true

  validation {
    condition     = var.public_network_access_enabled || (length(var.network_acls.ip_rules) == 0 && length(var.network_acls.virtual_network_subnet_ids) == 0)
    error_message = "network_acls.ip_rules and network_acls.virtual_network_subnet_ids have no effect while public_network_access_enabled is false."
  }
}

variable "network_acls" {
  description = "Network rules for the account. The defaults (Allow, no bypass, no rules) reproduce the fixed block this module used before. IP and subnet rules apply only when default_action is Deny; subnets need the Microsoft.CognitiveServices service endpoint."
  type = object({
    default_action             = optional(string, "Allow")
    bypass                     = optional(string, "None")
    ip_rules                   = optional(set(string), [])
    virtual_network_subnet_ids = optional(set(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["Allow", "Deny"], var.network_acls.default_action)
    error_message = "network_acls.default_action must be Allow or Deny."
  }

  validation {
    condition     = contains(["None", "AzureServices"], var.network_acls.bypass)
    error_message = "network_acls.bypass must be None or AzureServices."
  }

  validation {
    condition     = var.network_acls.default_action == "Deny" || (length(var.network_acls.ip_rules) == 0 && length(var.network_acls.virtual_network_subnet_ids) == 0)
    error_message = "network_acls.ip_rules and network_acls.virtual_network_subnet_ids only apply when default_action is Deny."
  }
}

variable "managed_identities" {
  description = "Managed identities on the Foundry account. The system-assigned identity stays on by default because the Azure AI Search role assignments and the principal ID outputs use it; user-assigned identities can be added next to it."
  type = object({
    system_assigned            = optional(bool, true)
    user_assigned_resource_ids = optional(set(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.managed_identities.system_assigned || length(var.managed_identities.user_assigned_resource_ids) > 0
    error_message = "managed_identities needs system_assigned = true or at least one user-assigned identity, because Foundry projects require an identity on the account."
  }

  validation {
    condition     = var.managed_identities.system_assigned || var.project_connections.azure_ai_search == null
    error_message = "The Azure AI Search role assignments use the system-assigned identity of the account, so managed_identities.system_assigned must stay true when project_connections.azure_ai_search is set."
  }
}

variable "project_managed_identities" {
  description = "Managed identities on the optional Foundry project. The system-assigned identity stays on because the role assignments and connections created by this module use it; user-assigned identities can be added next to it."
  type = object({
    system_assigned            = optional(bool, true)
    user_assigned_resource_ids = optional(set(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.project_managed_identities.system_assigned || !var.create_project
    error_message = "project_managed_identities.system_assigned must stay true while create_project = true, because the role assignments and connections created by this module use the system-assigned identity of the project."
  }
}
