data "azurerm_client_config" "current" {}

locals {
  fireworks_feature_type        = "Microsoft.Features/featureProviders/subscriptionFeatureRegistrations@2021-07-01"
  fireworks_feature_provider_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Features/featureProviders/Microsoft.CognitiveServices"
}

# Feature state before this run, read at plan time; it decides whether the request below runs.
data "azapi_resource" "fireworks_feature_before" {
  type                   = local.fireworks_feature_type
  name                   = "Fireworks.EnableDeploy"
  parent_id              = local.fireworks_feature_provider_id
  ignore_not_found       = true
  response_export_values = ["properties.state"]
}

locals {
  fireworks_feature_registered_before = data.azapi_resource.fireworks_feature_before.exists && try(data.azapi_resource.fireworks_feature_before.output.properties.state, "") == "Registered"
}

# Requests the subscription-wide feature; exists only while it is not Registered, and destroy does not unregister it.
resource "azapi_resource_action" "fireworks_feature_registration" {
  for_each = toset(local.fireworks_feature_registered_before ? [] : ["Fireworks.EnableDeploy"])

  type                   = local.fireworks_feature_type
  resource_id            = "${local.fireworks_feature_provider_id}/subscriptionFeatureRegistrations/${each.value}"
  method                 = "PUT"
  body                   = { properties = {} }
  response_export_values = ["properties.state"]
}

# Azure approves the feature asynchronously, so read its state again after the request.
data "azapi_resource" "fireworks_feature_registration" {
  type                   = local.fireworks_feature_type
  name                   = "Fireworks.EnableDeploy"
  parent_id              = local.fireworks_feature_provider_id
  ignore_not_found       = true
  response_export_values = ["properties.state"]

  depends_on = [azapi_resource_action.fireworks_feature_registration]
}

locals {
  fireworks_feature_state      = try(data.azapi_resource.fireworks_feature_registration.output.properties.state, "NotRegistered")
  fireworks_feature_registered = data.azapi_resource.fireworks_feature_registration.exists && local.fireworks_feature_state == "Registered"
  # Pending and Registering mean Azure is approving the request; any other state means it did not take.
  fireworks_feature_message = contains(["Pending", "Registering"], local.fireworks_feature_state) ? (
    "Fireworks.EnableDeploy is ${local.fireworks_feature_state} in subscription ${var.subscription_id}. Azure is still approving the request; wait a few minutes, then run terraform plan again."
    ) : (
    "Fireworks.EnableDeploy is ${local.fireworks_feature_state} in subscription ${var.subscription_id}, so Fireworks models cannot be deployed and waiting will not change that. Run terraform apply, which sends the registration request while the feature is not Registered; if the state still does not move, run: az feature registration create --namespace Microsoft.CognitiveServices --name Fireworks.EnableDeploy. Then plan again once the state is Registered."
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
  create_project      = true
  # The deployment identity lives outside this root, so planning does not bind roles to the CLI caller.
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

# Lets the Foundry project's managed identity read Application Insights traces.
resource "azurerm_role_assignment" "project_app_insights_monitoring_reader" {
  scope                = module.azure_monitor.application_insights_id
  role_definition_name = "Monitoring Reader"
  principal_id         = module.foundry.project_identity_principal_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true
}

# Routes the account's platform metrics to Log Analytics; the shared module sends only logs.
resource "azurerm_monitor_diagnostic_setting" "foundry_account_metrics" {
  name                       = "foundry-metrics-to-law"
  target_resource_id         = module.foundry.account_id
  log_analytics_workspace_id = module.azure_monitor.log_analytics_workspace_id

  enabled_metric {
    category = "AllMetrics"
  }
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
        name      = var.model_name
        publisher = "Fireworks AI"
        version   = var.model_version
      }
      raiPolicyName        = "Microsoft.DefaultV2"
      versionUpgradeOption = "NoAutoUpgrade"
    }
    sku = {
      name     = "GlobalStandard"
      capacity = var.model_capacity_thousand_tpm
    }
  }

  response_export_values = ["properties.model", "properties.deploymentState", "sku"]

  # Replace the deployment, rather than update it in place, when the model changes.
  replace_triggers_external_values = [var.model_name]

  depends_on = [azurerm_role_assignment.deployment_user_foundry_owner]

  lifecycle {
    precondition {
      condition     = local.fireworks_feature_registered
      error_message = local.fireworks_feature_message
    }
    precondition {
      condition     = length(trimspace(var.model_version)) > 0 && !startswith(var.model_version, "REPLACE_")
      error_message = "Set model_version to an approved version returned by the Azure model catalog after Fireworks.EnableDeploy is Registered."
    }
  }

}
