resource "azurerm_log_analytics_workspace" "this" {
  name                = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.log_analytics_sku
  retention_in_days   = var.retention_in_days
  daily_quota_gb      = var.daily_quota_gb

  local_authentication_enabled = var.log_analytics_local_authentication_enabled

  tags = var.tags
}

resource "azurerm_application_insights" "this" {
  name                 = var.application_insights_name
  location             = var.location
  resource_group_name  = var.resource_group_name
  application_type     = var.application_insights_type
  workspace_id         = azurerm_log_analytics_workspace.this.id
  sampling_percentage  = var.sampling_percentage
  ip_masking_enabled   = var.ip_masking_enabled
  retention_in_days    = var.application_insights_retention_in_days
  daily_data_cap_in_gb = var.application_insights_daily_data_cap_in_gb

  # Keep AzureRM aligned with the explicit DisableLocalAuth update below.
  local_authentication_enabled = var.application_insights_local_authentication_enabled

  internet_ingestion_enabled = var.internet_ingestion_enabled
  internet_query_enabled     = var.internet_query_enabled

  tags = var.tags
}

resource "azapi_update_resource" "application_insights_local_auth" {
  type        = "Microsoft.Insights/components@2020-02-02"
  resource_id = azurerm_application_insights.this.id

  body = {
    properties = {
      DisableLocalAuth = !var.application_insights_local_authentication_enabled
    }
  }
}

# Table-level retention overrides for the shared tables that Foundry diagnostics populate; keyed by table name.
resource "azurerm_log_analytics_workspace_table" "this" {
  for_each = var.table_retention

  workspace_id            = azurerm_log_analytics_workspace.this.id
  name                    = each.key
  plan                    = "Analytics"
  retention_in_days       = each.value.retention_in_days
  total_retention_in_days = each.value.total_retention_in_days
}

# Role assignments on the workspace, keyed by a stable label.
resource "azurerm_role_assignment" "workspace" {
  for_each = var.workspace_role_assignments

  scope                            = azurerm_log_analytics_workspace.this.id
  role_definition_name             = each.value.role_definition_name
  principal_id                     = each.value.principal_id
  principal_type                   = each.value.principal_type
  description                      = each.value.description
  skip_service_principal_aad_check = each.value.principal_type == "ServicePrincipal"
}

resource "azurerm_management_lock" "workspace" {
  count = var.lock == null ? 0 : 1

  name       = coalesce(var.lock.name, "lock-${azurerm_log_analytics_workspace.this.name}")
  scope      = azurerm_log_analytics_workspace.this.id
  lock_level = var.lock.kind
  notes      = "Managed by Terraform. Remove the lock input before destroying the workspace."
}
