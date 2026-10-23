locals {
  account_identity_ids  = tolist(var.managed_identities.user_assigned_resource_ids)
  account_identity_type = var.managed_identities.system_assigned ? (length(local.account_identity_ids) > 0 ? "SystemAssigned, UserAssigned" : "SystemAssigned") : "UserAssigned"
  project_identity_ids  = tolist(var.project_managed_identities.user_assigned_resource_ids)
  project_identity_type = var.project_managed_identities.system_assigned ? (length(local.project_identity_ids) > 0 ? "SystemAssigned, UserAssigned" : "SystemAssigned") : "UserAssigned"

  # Roles that give a workload identity control of the account instead of use of it.
  broad_role_names = ["Owner", "Contributor", "User Access Administrator"]
}

resource "azurerm_cognitive_account" "this" {
  name                  = var.name
  location              = var.location
  resource_group_name   = var.resource_group_name
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = var.name

  local_auth_enabled            = false
  project_management_enabled    = true
  public_network_access_enabled = var.public_network_access_enabled

  identity {
    type         = local.account_identity_type
    identity_ids = length(local.account_identity_ids) == 0 ? null : local.account_identity_ids
  }

  network_acls {
    default_action = var.network_acls.default_action
    bypass         = var.network_acls.bypass
    ip_rules       = length(var.network_acls.ip_rules) == 0 ? null : var.network_acls.ip_rules

    dynamic "virtual_network_rules" {
      for_each = var.network_acls.virtual_network_subnet_ids
      content {
        subnet_id = virtual_network_rules.value
      }
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.security_profile != "production" || !var.public_network_access_enabled || var.network_acls.default_action == "Deny"
      error_message = "security_profile = production needs public_network_access_enabled = false or network_acls.default_action = Deny, so network exposure is an explicit decision."
    }

    precondition {
      condition     = var.security_profile != "production" || length(var.diagnostic_log_categories) > 0
      error_message = "security_profile = production needs at least one entry in diagnostic_log_categories."
    }

    precondition {
      condition     = var.security_profile != "production" || !anytrue([for r in values(var.role_assignments) : contains(local.broad_role_names, r.role_definition_name)])
      error_message = "security_profile = production does not allow Owner, Contributor or User Access Administrator in role_assignments; grant a Foundry role such as Foundry User instead."
    }
  }
}

resource "azurerm_cognitive_deployment" "model" {
  count                  = var.model_deployment == null ? 0 : 1
  name                   = var.model_deployment.name
  cognitive_account_id   = azurerm_cognitive_account.this.id
  rai_policy_name        = var.model_deployment.rai_policy_name
  version_upgrade_option = var.model_deployment.version_upgrade_option

  model {
    format  = var.model_deployment.format
    name    = var.model_deployment.model_name
    version = var.model_deployment.model_version
  }

  sku {
    name     = var.model_deployment.sku_name
    capacity = var.model_deployment.capacity
  }

  timeouts {
    create = "30m"
    update = "30m"
  }
}

# Categories are driven by var.diagnostic_log_categories; the defaults reproduce the original four static blocks.
resource "azurerm_monitor_diagnostic_setting" "account" {
  name                       = "foundry-to-law"
  target_resource_id         = azurerm_cognitive_account.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  dynamic "enabled_log" {
    for_each = var.diagnostic_log_categories
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = var.diagnostic_metric_categories
    content {
      category = enabled_metric.value
    }
  }
}

resource "azurerm_cognitive_account_project" "this" {
  count                = var.create_project ? 1 : 0
  name                 = var.project_name
  cognitive_account_id = azurerm_cognitive_account.this.id
  location             = var.location
  description          = var.project_description
  display_name         = var.project_display_name

  identity {
    type         = local.project_identity_type
    identity_ids = length(local.project_identity_ids) == 0 ? null : local.project_identity_ids
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "project_account_foundry_user" {
  count                = var.create_project ? 1 : 0
  scope                = azurerm_cognitive_account.this.id
  role_definition_name = "Foundry User"
  principal_id         = azurerm_cognitive_account_project.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "account_search_index_contributor" {
  count                = var.create_project && var.project_connections.azure_ai_search != null ? 1 : 0
  scope                = var.project_connections.azure_ai_search.resource_id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = azurerm_cognitive_account.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "account_search_service_contributor" {
  count                = var.create_project && var.project_connections.azure_ai_search != null ? 1 : 0
  scope                = var.project_connections.azure_ai_search.resource_id
  role_definition_name = "Search Service Contributor"
  principal_id         = azurerm_cognitive_account.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

# The agent runtime authorises Azure AI Search queries with the Foundry project's
# managed identity. Keep the account identity assignments above for account-level
# Search operations, and grant the runtime identity the roles required by the
# Azure AI Search agent tool.
resource "azurerm_role_assignment" "project_search_index_contributor" {
  count                = var.create_project && var.project_connections.azure_ai_search != null ? 1 : 0
  scope                = var.project_connections.azure_ai_search.resource_id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = azurerm_cognitive_account_project.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "project_search_service_contributor" {
  count                = var.create_project && var.project_connections.azure_ai_search != null ? 1 : 0
  scope                = var.project_connections.azure_ai_search.resource_id
  role_definition_name = "Search Service Contributor"
  principal_id         = azurerm_cognitive_account_project.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "project_app_insights_metrics_publisher" {
  count                = var.create_project && var.project_connections.application_insights != null ? 1 : 0
  scope                = var.project_connections.application_insights.resource_id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_cognitive_account_project.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "deployment_project_manager" {
  count                = var.create_project && var.deployment_principal_id != null ? 1 : 0
  scope                = azurerm_cognitive_account_project.this[0].id
  role_definition_name = "Foundry Project Manager"
  principal_id         = var.deployment_principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "deployment_account_foundry_user" {
  count                = var.create_project && var.deployment_principal_id != null ? 1 : 0
  scope                = azurerm_cognitive_account.this.id
  role_definition_name = "Foundry User"
  principal_id         = var.deployment_principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

resource "azapi_resource" "application_insights_connection" {
  count                     = var.create_project && var.project_connections.application_insights != null ? 1 : 0
  type                      = "Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01"
  name                      = "appinsights-connection"
  parent_id                 = azurerm_cognitive_account_project.this[0].id
  schema_validation_enabled = false

  body = {
    properties = {
      authType      = "ProjectManagedIdentity"
      category      = "AppInsights"
      isSharedToAll = false
      target        = var.project_connections.application_insights.resource_id
    }
  }

  sensitive_body = {
    properties = {
      metadata = {
        ApiType                             = "Azure"
        ApplicationInsightsConnectionString = var.application_insights_connection_string
        ResourceId                          = var.project_connections.application_insights.resource_id
        location                            = var.project_connections.application_insights.location
      }
    }
  }

  depends_on = [azurerm_role_assignment.project_app_insights_metrics_publisher]
}

resource "azapi_resource" "bing_connection" {
  count     = var.create_project && var.project_connections.bing_grounding != null ? 1 : 0
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01"
  name      = "bing-grounding"
  parent_id = azurerm_cognitive_account_project.this[0].id

  body = {
    properties = {
      authType      = "ApiKey"
      category      = "GroundingWithBingSearch"
      isSharedToAll = false
      target        = var.project_connections.bing_grounding.endpoint
      metadata = {
        type       = "bing_grounding"
        ApiType    = "Azure"
        ResourceId = var.project_connections.bing_grounding.resource_id
        location   = "global"
      }
    }
  }

  sensitive_body = {
    properties = {
      credentials = {
        key = var.bing_grounding_key
      }
    }
  }

  depends_on = [
    azapi_resource.application_insights_connection,
    azurerm_role_assignment.deployment_project_manager,
  ]
}

resource "azapi_resource" "azure_ai_search_connection" {
  count     = var.create_project && var.project_connections.azure_ai_search != null ? 1 : 0
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01"
  name      = var.project_connections.azure_ai_search.connection_name
  parent_id = azurerm_cognitive_account_project.this[0].id

  body = {
    properties = {
      authType      = "AAD"
      category      = "CognitiveSearch"
      isSharedToAll = false
      target        = var.project_connections.azure_ai_search.endpoint
      metadata = {
        ApiType    = "Azure"
        ResourceId = var.project_connections.azure_ai_search.resource_id
        location   = var.project_connections.azure_ai_search.location
      }
    }
  }

  depends_on = [
    azapi_resource.bing_connection,
    azurerm_role_assignment.account_search_index_contributor,
    azurerm_role_assignment.account_search_service_contributor,
    azurerm_role_assignment.project_search_index_contributor,
    azurerm_role_assignment.project_search_service_contributor,
    azurerm_role_assignment.deployment_project_manager,
  ]
}

# Project-level diagnostics are opt-in; the project exposes Audit and Trace logs plus its own metrics.
resource "azurerm_monitor_diagnostic_setting" "project" {
  count = var.create_project && var.project_diagnostics_enabled ? 1 : 0

  name                       = "foundry-project-to-law"
  target_resource_id         = azurerm_cognitive_account_project.this[0].id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  dynamic "enabled_log" {
    for_each = var.project_diagnostic_log_categories
    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Generic role assignments on the account, keyed by a stable label so adding one never renumbers another.
resource "azurerm_role_assignment" "account" {
  for_each = var.role_assignments

  scope                            = azurerm_cognitive_account.this.id
  role_definition_name             = each.value.role_definition_name
  principal_id                     = each.value.principal_id
  principal_type                   = each.value.principal_type
  description                      = each.value.description
  condition                        = each.value.condition
  condition_version                = each.value.condition_version
  skip_service_principal_aad_check = each.value.principal_type == "ServicePrincipal"
}

resource "azurerm_management_lock" "account" {
  count = var.lock == null ? 0 : 1

  name       = coalesce(var.lock.name, "lock-${azurerm_cognitive_account.this.name}")
  scope      = azurerm_cognitive_account.this.id
  lock_level = var.lock.kind
  notes      = "Managed by Terraform. Remove the lock input before destroying the account."
}
