module "service_plan" {
  count   = var.service_plan_resource_id == null ? 1 : 0
  source  = "Azure/avm-res-web-serverfarm/azurerm"
  version = "2.0.8"

  name                   = coalesce(var.service_plan_name, "asp-${var.name}")
  parent_id              = var.resource_group_id
  location               = var.location
  os_type                = "Linux"
  sku_name               = var.service_plan_sku_name
  worker_count           = var.service_plan_worker_count
  zone_balancing_enabled = var.service_plan_zone_balancing_enabled

  enable_telemetry = false
}

locals {
  raw_service_plan_id = var.service_plan_resource_id != null ? var.service_plan_resource_id : module.service_plan[0].resource_id
  service_plan_id     = replace(local.raw_service_plan_id, "serverfarms", "serverFarms")
  diagnostic_categories = var.enable_diagnostics ? setintersection(
    toset([
      "AppServiceHTTPLogs",
      "AppServiceConsoleLogs",
      "AppServiceAppLogs",
      "AppServicePlatformLogs",
      "AppServiceAuthenticationLogs",
    ]),
    toset(data.azurerm_monitor_diagnostic_categories.this[0].log_category_types),
  ) : toset([])
}

data "azurerm_monitor_diagnostic_categories" "this" {
  count       = var.enable_diagnostics ? 1 : 0
  resource_id = azurerm_linux_web_app.this.id
}

resource "azurerm_linux_web_app" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = local.service_plan_id

  https_only                                     = var.https_only
  public_network_access_enabled                  = var.public_network_access_enabled
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type = var.identity_type
  }

  app_settings = var.app_settings

  site_config {
    always_on           = var.always_on
    ftps_state          = var.ftps_state
    http2_enabled       = var.http2_enabled
    minimum_tls_version = var.minimum_tls_version

    application_stack {
      dotnet_version      = var.application_stack.dotnet_version
      go_version          = var.application_stack.go_version
      java_server         = var.application_stack.java_server
      java_server_version = var.application_stack.java_server_version
      java_version        = var.application_stack.java_version
      node_version        = var.application_stack.node_version
      php_version         = var.application_stack.php_version
      python_version      = var.application_stack.python_version
    }
  }

  dynamic "auth_settings_v2" {
    for_each = var.authentication.enabled ? [var.authentication] : []

    content {
      auth_enabled           = true
      require_authentication = true
      unauthenticated_action = auth_settings_v2.value.unauthenticated_action
      default_provider       = "azureactivedirectory"
      require_https          = true

      active_directory_v2 {
        client_id                  = auth_settings_v2.value.client_id
        tenant_auth_endpoint       = "https://login.microsoftonline.com/${auth_settings_v2.value.tenant_id}/v2.0/"
        client_secret_setting_name = auth_settings_v2.value.client_secret_setting_name
        allowed_audiences          = auth_settings_v2.value.allowed_audiences
      }

      login {
        token_store_enabled = false
      }
    }
  }

  logs {
    application_logs {
      file_system_level = var.application_log_level
    }

    http_logs {
      file_system {
        retention_in_days = var.http_log_retention_in_days
        retention_in_mb   = var.http_log_retention_in_mb
      }
    }
  }

  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count                      = var.enable_diagnostics ? 1 : 0
  name                       = "${var.name}-to-law"
  target_resource_id         = azurerm_linux_web_app.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  dynamic "enabled_log" {
    for_each = local.diagnostic_categories
    content {
      category = enabled_log.value
    }
  }
}
