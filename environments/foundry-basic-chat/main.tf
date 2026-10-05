data "azurerm_client_config" "current" {}

locals {
  regional_name = "${var.workload_name}-${var.environment}-${var.region_code}-${var.instance}"
  global_name   = "${var.workload_name}-${var.environment}-${var.instance}"

  tags = merge(var.tags, {
    Application = var.workload_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Series      = "1"
  })
}

module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "0.4.0"

  name             = var.resource_group_name
  location         = var.location
  tags             = local.tags
  enable_telemetry = false
}

module "azure_monitor" {
  source = "../../modules/azure-monitor"

  log_analytics_workspace_name = "log-${local.regional_name}"
  application_insights_name    = "appi-${local.regional_name}"
  location                     = module.resource_group.location
  resource_group_name          = module.resource_group.name
  tags                         = local.tags
}

module "foundry" {
  source = "../../modules/foundry"

  name                    = "aif-${local.regional_name}"
  project_name            = "proj-${local.regional_name}"
  location                = module.resource_group.location
  resource_group_name     = module.resource_group.name
  create_project          = true
  deployment_principal_id = data.azurerm_client_config.current.object_id
  model_deployment = {
    name                   = "agent-model"
    model_name             = "gpt-4.1"
    model_version          = "2025-04-14"
    sku_name               = "GlobalStandard"
    capacity               = 50
    rai_policy_name        = "Microsoft.DefaultV2"
    version_upgrade_option = "NoAutoUpgrade"
  }
  log_analytics_workspace_id             = module.azure_monitor.log_analytics_workspace_id
  application_insights_connection_string = module.azure_monitor.application_insights_connection_string
  project_connections = {
    application_insights = {
      resource_id = module.azure_monitor.application_insights_id
      location    = module.resource_group.location
    }
    bing_grounding = {
      resource_id = module.bing_grounding.resource_id
      endpoint    = module.bing_grounding.endpoint
    }
    azure_ai_search = {
      resource_id     = module.azure_ai_search.search_service_id
      endpoint        = module.azure_ai_search.search_service_endpoint
      location        = module.resource_group.location
      connection_name = "azure-ai-search"
    }
  }
  bing_grounding_key = module.bing_grounding.key
  tags               = local.tags
}

module "bing_grounding" {
  source = "../../modules/bing-grounding"

  name              = "bing-${local.regional_name}"
  resource_group_id = module.resource_group.resource_id
  tags              = local.tags
}

module "azure_ai_search" {
  source = "../../modules/azure-ai-search"

  name                       = "srch-${local.regional_name}"
  location                   = module.resource_group.location
  resource_group_name        = module.resource_group.name
  log_analytics_workspace_id = module.azure_monitor.log_analytics_workspace_id
  deployment_principal_id    = data.azurerm_client_config.current.object_id
  tags                       = local.tags
}

module "web_app" {
  source = "../../modules/web-app"

  name                      = "app-${local.global_name}"
  service_plan_name         = "asp-${local.regional_name}"
  location                  = module.resource_group.location
  resource_group_name       = module.resource_group.name
  resource_group_id         = module.resource_group.resource_id
  service_plan_sku_name     = "B1"
  service_plan_worker_count = 1
  enable_diagnostics        = true
  application_log_level     = "Verbose"
  application_stack = {
    dotnet_version = "10.0"
  }
  app_settings = {
    AIProjectEndpoint                          = module.foundry.project_endpoint
    AIAgentId                                  = var.agent_name
    AIAgentVersion                             = var.agent_version
    APPLICATIONINSIGHTS_CONNECTION_STRING      = module.azure_monitor.application_insights_connection_string
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING  = "Authorization=AAD"
    ApplicationInsightsAgent_EXTENSION_VERSION = "~3"
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET   = var.easy_auth_client_secret
    XDT_MicrosoftApplicationInsights_Mode      = "Recommended"
  }
  authentication = {
    enabled                    = true
    client_id                  = var.easy_auth_client_id
    tenant_id                  = data.azurerm_client_config.current.tenant_id
    client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
    allowed_audiences          = [var.easy_auth_client_id]
  }
  log_analytics_workspace_id = module.azure_monitor.log_analytics_workspace_id
  tags                       = local.tags
}

resource "azurerm_role_assignment" "web_app_foundry_user" {
  scope                = module.foundry.account_id
  role_definition_name = "Foundry User"
  principal_id         = module.web_app.identity_principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "web_app_app_insights_metrics_publisher" {
  scope                = module.azure_monitor.application_insights_id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = module.web_app.identity_principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

output "resource_group_name" {
  description = "Resource group containing this independent proof of concept."
  value       = module.resource_group.name
}

output "foundry_account_name" {
  description = "Microsoft Foundry account name."
  value       = module.foundry.account_name
}

output "foundry_project_endpoint" {
  description = "Project endpoint used by the chat application and agent bootstrap."
  value       = module.foundry.project_endpoint
}

output "search_endpoint" {
  description = "Azure AI Search endpoint used for grounding."
  value       = module.azure_ai_search.search_service_endpoint
}

output "search_index_name" {
  description = "Name of the index created by the bootstrap script."
  value       = var.search_index_name
}

output "search_connection_id" {
  description = "Foundry project connection resource ID for Azure AI Search."
  value       = module.foundry.azure_ai_search_connection_id
}

output "bing_connection_id" {
  description = "Foundry project connection resource ID for Bing Grounding."
  value       = module.foundry.bing_connection_id
}

output "web_app_name" {
  description = "App Service name for the chat application."
  value       = module.web_app.web_app_name
}

output "web_app_url" {
  description = "HTTPS URL for the authenticated chat application."
  value       = module.web_app.web_app_url
}

output "agent_name" {
  description = "Named prompt agent referenced by the application."
  value       = var.agent_name
}

output "agent_version" {
  description = "Prompt agent version referenced by the application."
  value       = var.agent_version
}
