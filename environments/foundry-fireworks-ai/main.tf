data "azurerm_client_config" "current" {}

# Request the subscription-wide pre-release feature. The POST is idempotent and
# destroy does not unregister it, so other Fireworks workloads are unaffected.
resource "azapi_resource_action" "fireworks_feature_registration" {
  type                   = "Microsoft.Features/providers/features@2021-07-01"
  resource_id            = "/subscriptions/${var.subscription_id}/providers/Microsoft.Features/providers/Microsoft.CognitiveServices/features/Fireworks.EnableDeploy"
  action                 = "register"
  method                 = "POST"
  response_export_values = ["properties.state"]
}

# Azure approves the feature asynchronously, so read its state after the request.
data "azapi_resource" "fireworks_feature_registration" {
  type                   = "Microsoft.Features/featureProviders/subscriptionFeatureRegistrations@2021-07-01"
  name                   = "Fireworks.EnableDeploy"
  parent_id              = "/subscriptions/${var.subscription_id}/providers/Microsoft.Features/featureProviders/Microsoft.CognitiveServices"
  ignore_not_found       = true
  response_export_values = ["properties.state"]

  depends_on = [azapi_resource_action.fireworks_feature_registration]
}

locals {
  regional_name = "${var.workload_name}-${var.environment}-${var.region_code}-${var.instance}"

  tags = {
    Application        = var.workload_name
    BusinessUnit       = var.business_unit
    Criticality        = var.criticality
    DataClassification = var.data_classification
    Department         = var.department
    Environment        = var.environment
    ManagedBy          = "Terraform"
    Owner              = var.owner
    OpsTeam            = var.ops_team
    Project            = var.project
    Region             = var.location
    ServiceLevel       = var.service_level
    SupportGroup       = var.support_group
  }
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

  name                = "aif-${local.regional_name}"
  project_name        = "proj-${local.regional_name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  create_project      = true
  # The deployment identity is provisioned outside this root so planning does
  # not bind role assignments to the Azure CLI caller.
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
  tags = local.tags
}

resource "azurerm_role_assignment" "deployment_user_foundry_owner" {
  scope                = module.foundry.account_id
  role_definition_name = "Foundry Owner"
  principal_id         = data.azurerm_client_config.current.object_id
  principal_type       = "User"

  skip_service_principal_aad_check = false
}

resource "azapi_resource" "fireworks_model_deployment" {
  type                      = "Microsoft.CognitiveServices/accounts/deployments@2026-07-01"
  name                      = var.model_deployment_name
  parent_id                 = module.foundry.account_id
  schema_validation_enabled = false
  tags                      = local.tags

  body = {
    properties = {
      deploymentState = "Running"
      model = {
        format    = "Fireworks"
        name      = "FW-DeepSeek-V4.1-Flash"
        publisher = "Fireworks AI"
        version   = var.model_version
      }
      raiPolicyName        = "Microsoft.DefaultV2"
      versionUpgradeOption = "NoAutoUpgrade"
    }
    sku = {
      name     = "GlobalStandard"
      capacity = var.model_capacity
    }
  }

  response_export_values = ["properties.model", "properties.deploymentState", "sku"]

  depends_on = [azurerm_role_assignment.deployment_user_foundry_owner]

  lifecycle {
    precondition {
      condition     = data.azapi_resource.fireworks_feature_registration.exists && try(data.azapi_resource.fireworks_feature_registration.output.properties.state, "") == "Registered"
      error_message = "Fireworks.EnableDeploy registration was requested but is not yet Registered in the target subscription. Wait a few minutes, then run terraform plan again."
    }
    precondition {
      condition     = length(trimspace(var.model_version)) > 0 && !startswith(var.model_version, "REPLACE_")
      error_message = "Set model_version to an approved version returned by the Azure model catalog after Fireworks.EnableDeploy is Registered."
    }
  }

}
