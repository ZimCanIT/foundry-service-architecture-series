resource "azurerm_search_service" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "basic"

  local_authentication_enabled = false

  tags = var.tags
}

resource "azurerm_role_assignment" "deployment_service_contributor" {
  scope                = azurerm_search_service.this.id
  role_definition_name = "Search Service Contributor"
  principal_id         = var.deployment_principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "deployment_index_contributor" {
  scope                = azurerm_search_service.this.id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = var.deployment_principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

data "azurerm_monitor_diagnostic_categories" "this" {
  resource_id = azurerm_search_service.this.id
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = "search-to-law"
  target_resource_id         = azurerm_search_service.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  dynamic "enabled_log" {
    for_each = toset(data.azurerm_monitor_diagnostic_categories.this.log_category_types)
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = toset(data.azurerm_monitor_diagnostic_categories.this.metrics)
    content {
      category = enabled_metric.value
    }
  }

  depends_on = [azurerm_role_assignment.deployment_index_contributor]
}
