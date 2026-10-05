resource "azurerm_log_analytics_workspace" "this" {
  name                = var.log_analytics_workspace_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 10

  local_authentication_enabled = false

  tags = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = var.application_insights_name
  location            = var.location
  resource_group_name = var.resource_group_name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.this.id

  # Keep AzureRM aligned with the explicit DisableLocalAuth update below.
  local_authentication_enabled = false

  internet_ingestion_enabled = true
  internet_query_enabled     = true

  tags = var.tags
}

resource "azapi_update_resource" "application_insights_local_auth" {
  type        = "Microsoft.Insights/components@2020-02-02"
  resource_id = azurerm_application_insights.this.id

  body = {
    properties = {
      DisableLocalAuth = true
    }
  }
}
