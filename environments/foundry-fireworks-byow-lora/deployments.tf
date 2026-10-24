locals {
  resource_types = {
    cognitive_deployment = "Microsoft.CognitiveServices/accounts/deployments@2025-06-01"
  }

  # ARM-shaped, so the block can later move into a shared deployments module with a moved block.
  deployments = {
    for name, adapter in var.adapters : name => {
      model = {
        format  = "FireworksCustom"
        name    = adapter.model_name
        version = adapter.model_version
        source  = local.foundry.project_id
      }
      rai_policy_name        = "Microsoft.DefaultV2"
      version_upgrade_option = "NoAutoUpgrade"
      sku = {
        name     = "GlobalProvisionedManaged"
        capacity = adapter.ptu_capacity
      }
    }
  }

  # concat with 0 keeps sum() defined when the map is empty.
  ptu_total = sum(concat([0], [for adapter in values(var.adapters) : adapter.ptu_capacity]))
}

# Each instance starts an hourly Global Provisioned meter that runs until the deployment is deleted.
resource "azapi_resource" "byow_deployment" {
  for_each = local.deployments

  type      = local.resource_types.cognitive_deployment
  name      = each.key
  parent_id = local.foundry.account_id
  tags      = merge(local.tags, { PtuApprover = var.ptu_gate.approver })

  body = {
    properties = {
      model                = each.value.model
      raiPolicyName        = each.value.rai_policy_name
      versionUpgradeOption = each.value.version_upgrade_option
    }
    sku = each.value.sku
  }

  response_export_values = ["properties.provisioningState", "properties.model", "sku"]

  # Budget, action group and role assignments exist before the meter starts.
  depends_on = [module.foundry, azurerm_consumption_budget_resource_group.this]

  lifecycle {
    precondition {
      condition     = local.fireworks_feature_registered
      error_message = local.fireworks_feature_message
    }
    precondition {
      condition     = local.foundry.project_id != null
      error_message = "The deployment source is the Foundry project, so the project must exist."
    }
    precondition {
      condition     = !startswith(each.value.model.name, "REPLACE_") && !startswith(each.value.model.version, "REPLACE_")
      error_message = "Set adapters[\"${each.key}\"].model_name and model_version to the name and version the Foundry portal shows as Registered."
    }
    precondition {
      condition     = var.ptu_gate.approved && length(trimspace(var.ptu_gate.approver)) > 0
      error_message = "Global Provisioned capacity bills hourly from creation to deletion. Set ptu_gate.approved and ptu_gate.approver after the approver has read the saved plan."
    }
    precondition {
      condition     = var.ptu_gate.cap > 0 && local.ptu_total <= var.ptu_gate.cap
      error_message = "The adapters ask for ${local.ptu_total} PTUs and ptu_gate.cap is ${var.ptu_gate.cap}. Change the cap only with the approver."
    }
    precondition {
      condition     = length(distinct([for adapter in values(var.adapters) : adapter.model_name])) == length(var.adapters)
      error_message = "Only one active deployment of an imported custom model is allowed per project; give each entry its own registered model."
    }
  }
}

# A warning, not an error: the service decides which capacities are valid, and no page states
# the grid for a custom import, so the values are copied from the portal's deploy dialog.
check "ptu_grid" {
  assert {
    condition = length(var.adapters) == 0 ? true : (
      var.ptu_gate.minimum == null || var.ptu_gate.increment == null ? false : alltrue([
        for adapter in values(var.adapters) :
        adapter.ptu_capacity >= var.ptu_gate.minimum && (adapter.ptu_capacity - var.ptu_gate.minimum) % var.ptu_gate.increment == 0
      ])
    )
    error_message = "Each ptu_capacity should be the portal minimum plus whole increments. Copy ptu_gate.minimum and ptu_gate.increment from the custom model's deploy dialog. This is a warning; Azure decides."
  }
}
