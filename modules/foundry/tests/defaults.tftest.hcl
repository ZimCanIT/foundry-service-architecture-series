# Plan-only tests. Both providers are mocked, so nothing here reaches Azure.
# The defaults must keep reproducing the account that the first video deploys.

# Mocked IDs are random strings, which the provider rejects as a diagnostic target in the apply run below.
mock_provider "azurerm" {
  mock_resource "azurerm_cognitive_account" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.CognitiveServices/accounts/aif-test"
    }
  }
}
mock_provider "azapi" {}

variables {
  name                                   = "aif-test"
  location                               = "uksouth"
  resource_group_name                    = "rg-test"
  log_analytics_workspace_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test"
  application_insights_connection_string = "InstrumentationKey=00000000-0000-0000-0000-000000000000"
}

run "account_matches_the_baseline" {
  command = plan

  assert {
    condition     = azurerm_cognitive_account.this.kind == "AIServices" && azurerm_cognitive_account.this.sku_name == "S0"
    error_message = "The account must stay an AIServices S0 account."
  }

  assert {
    condition     = azurerm_cognitive_account.this.local_auth_enabled == false
    error_message = "Local key authentication must stay off."
  }

  assert {
    condition     = azurerm_cognitive_account.this.project_management_enabled == true
    error_message = "Project management must stay on."
  }

  assert {
    condition     = azurerm_cognitive_account.this.public_network_access_enabled == true
    error_message = "The baseline keeps public network access on."
  }

  assert {
    condition     = azurerm_cognitive_account.this.identity[0].type == "SystemAssigned"
    error_message = "The account must keep only the system-assigned identity by default."
  }

  assert {
    condition     = try(length(azurerm_cognitive_account.this.identity[0].identity_ids), 0) == 0
    error_message = "No user-assigned identity may be attached by default."
  }

  assert {
    condition     = azurerm_cognitive_account.this.network_acls[0].default_action == "Allow" && azurerm_cognitive_account.this.network_acls[0].bypass == "None"
    error_message = "The default network rules must stay Allow with no bypass."
  }

  assert {
    condition     = try(length(azurerm_cognitive_account.this.network_acls[0].ip_rules), 0) == 0 && length(azurerm_cognitive_account.this.network_acls[0].virtual_network_rules) == 0
    error_message = "No IP or subnet rule may be rendered by default."
  }
}

run "diagnostics_keep_the_original_four_categories" {
  command = plan

  assert {
    condition     = toset([for l in azurerm_monitor_diagnostic_setting.account.enabled_log : l.category]) == toset(["Audit", "RequestResponse", "AzureOpenAIRequestUsage", "Trace"])
    error_message = "The account diagnostic setting must send the four original log categories."
  }

  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.account.enabled_metric) == 0
    error_message = "No metric category may be sent by default."
  }
}

run "optional_resources_are_off" {
  command = plan

  assert {
    condition = alltrue([
      length(azurerm_cognitive_deployment.model) == 0,
      length(azurerm_cognitive_account_project.this) == 0,
      length(azurerm_management_lock.account) == 0,
      length(azurerm_role_assignment.account) == 0,
      length(azurerm_monitor_diagnostic_setting.project) == 0,
      length(azapi_resource.application_insights_connection) == 0,
      length(azapi_resource.bing_connection) == 0,
      length(azapi_resource.azure_ai_search_connection) == 0,
    ])
    error_message = "Every optional resource must stay off until it is asked for."
  }
}

run "optional_outputs_are_null" {
  command = plan

  assert {
    condition = alltrue([
      output.project_id == null,
      output.project_name == null,
      output.project_endpoint == null,
      output.project_identity_principal_id == null,
      output.model_deployment_name == null,
      output.model_deployment_metadata == null,
      output.azure_ai_search_connection_id == null,
      output.bing_connection_id == null,
      output.application_insights_connection_id == null,
      output.project_resource_id == null,
    ])
    error_message = "Every optional output must be null while its resource is off."
  }
}

# Computed values exist only after an apply, which the mocked providers can simulate.
run "aliases_mirror_the_original_outputs" {
  command = apply

  assert {
    condition     = output.resource_id == output.account_id && output.name == output.account_name
    error_message = "resource_id and name must mirror account_id and account_name."
  }

  assert {
    condition     = output.system_assigned_mi_principal_id == output.account_identity_principal_id && output.system_assigned_mi_principal_id != null
    error_message = "system_assigned_mi_principal_id must mirror account_identity_principal_id while the system-assigned identity is on."
  }
}
