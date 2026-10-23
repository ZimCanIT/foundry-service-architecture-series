data "azurerm_client_config" "current" {}

# Read only: the Fireworks environment owns the subscription-wide registration request,
# so this root checks the state and stops the deployment with a message if it is missing.
data "azapi_resource" "fireworks_feature" {
  type                   = "Microsoft.Features/featureProviders/subscriptionFeatureRegistrations@2021-07-01"
  name                   = "Fireworks.EnableDeploy"
  parent_id              = "/subscriptions/${var.subscription_id}/providers/Microsoft.Features/featureProviders/Microsoft.CognitiveServices"
  ignore_not_found       = true
  response_export_values = ["properties.state"]
}

locals {
  fireworks_feature_state      = try(data.azapi_resource.fireworks_feature.output.properties.state, "NotRegistered")
  fireworks_feature_registered = data.azapi_resource.fireworks_feature.exists && local.fireworks_feature_state == "Registered"
  # Pending and Registering mean Azure is approving the request; any other state means it was not requested.
  fireworks_feature_message = contains(["Pending", "Registering"], local.fireworks_feature_state) ? (
    "Fireworks.EnableDeploy is ${local.fireworks_feature_state} in subscription ${var.subscription_id}. Azure is still approving the request; wait a few minutes, then run terraform plan again."
    ) : (
    "Fireworks.EnableDeploy is ${local.fireworks_feature_state} in subscription ${var.subscription_id}. This root does not request it. Apply environments/foundry-fireworks-model-deployment once, or run: az feature registration create --namespace Microsoft.CognitiveServices --name Fireworks.EnableDeploy. Then plan again once the state is Registered."
  )
}

# Random suffix that keeps the Foundry account name, and so its endpoint, globally unique.
resource "random_string" "foundry_account_suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  regional_name        = "${var.workload_name}-${var.environment}-${var.region_code}-${var.instance}"
  foundry_account_name = "aif-${local.regional_name}-${random_string.foundry_account_suffix.result}"

  tags = {
    Application        = var.workload_name
    BusinessUnit       = var.business_unit
    Criticality        = var.criticality
    DataClassification = var.data_classification
    Department         = var.department
    Environment        = var.environment
    ManagedBy          = var.managed_by
    Owner              = var.owner
    OpsTeam            = var.ops_team
    Project            = var.project
    Region             = var.location
    ServiceLevel       = var.service_level
    SupportGroup       = var.support_group
  }

  # Module outputs under the names this root uses, so a module output rename touches one place.
  foundry = {
    account_id           = module.foundry.account_id
    account_name         = module.foundry.account_name
    account_endpoint     = module.foundry.account_endpoint
    project_id           = module.foundry.project_id
    project_name         = module.foundry.project_name
    project_endpoint     = module.foundry.project_endpoint
    project_principal_id = module.foundry.project_identity_principal_id
  }

  # The deploying user creates deployments and uploads adapters; inference principals call them keylessly.
  foundry_role_assignments = merge(
    {
      deployer = {
        role_definition_name = "Foundry Owner"
        principal_id         = data.azurerm_client_config.current.object_id
        principal_type       = "User"
      }
    },
    {
      for key, principal in var.inference_principals : "inference-${key}" => {
        role_definition_name = principal.role
        principal_id         = principal.principal_id
        principal_type       = principal.principal_type
      }
    }
  )
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

module "azure_monitor" {
  source = "../../modules/azure-monitor"

  log_analytics_workspace_name = "log-${local.regional_name}"
  application_insights_name    = "appi-${local.regional_name}"
  location                     = azurerm_resource_group.this.location
  resource_group_name          = azurerm_resource_group.this.name
  tags                         = local.tags
}

module "foundry" {
  source = "../../modules/foundry"

  name                = local.foundry_account_name
  project_name        = "proj-${local.regional_name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  # The adapter is registered in the project and the deployment source is the project.
  create_project = true
  # The deployer's role comes from role_assignments; no catalogue deployment is created here.
  deployment_principal_id                = null
  model_deployment                       = null
  log_analytics_workspace_id             = module.azure_monitor.log_analytics_workspace_id
  application_insights_connection_string = module.azure_monitor.application_insights_connection_string
  project_connections = {
    application_insights = {
      resource_id = module.azure_monitor.application_insights_id
      location    = azurerm_resource_group.this.location
    }
  }
  # RequestResponse feeds read_logs.sh; token metrics reach the workspace only through AllMetrics.
  diagnostic_log_categories    = ["Audit", "RequestResponse"]
  diagnostic_metric_categories = ["AllMetrics"]
  role_assignments             = local.foundry_role_assignments
  tags                         = local.tags
}

# Lets the Foundry project's managed identity read Application Insights traces.
resource "azurerm_role_assignment" "project_app_insights_monitoring_reader" {
  scope                = module.azure_monitor.application_insights_id
  role_definition_name = "Monitoring Reader"
  principal_id         = local.foundry.project_principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}
