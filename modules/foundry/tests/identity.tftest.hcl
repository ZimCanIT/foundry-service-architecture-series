# Plan-only tests for managed identities on the account and the optional project.

mock_provider "azurerm" {}
mock_provider "azapi" {}

variables {
  name                                   = "aif-test"
  location                               = "uksouth"
  resource_group_name                    = "rg-test"
  log_analytics_workspace_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test"
  application_insights_connection_string = "InstrumentationKey=00000000-0000-0000-0000-000000000000"
}

run "account_accepts_only_a_user_assigned_identity" {
  command = plan

  variables {
    managed_identities = {
      system_assigned            = false
      user_assigned_resource_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test"]
    }
  }

  assert {
    condition     = azurerm_cognitive_account.this.identity[0].type == "UserAssigned" && length(azurerm_cognitive_account.this.identity[0].identity_ids) == 1
    error_message = "The account must carry exactly one user-assigned identity and no system-assigned identity."
  }
}

run "account_accepts_both_identity_kinds" {
  command = plan

  variables {
    managed_identities = {
      user_assigned_resource_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test"]
    }
  }

  assert {
    condition     = azurerm_cognitive_account.this.identity[0].type == "SystemAssigned, UserAssigned"
    error_message = "The account must carry both identity kinds."
  }
}

run "account_needs_an_identity" {
  command = plan

  variables {
    managed_identities = {
      system_assigned = false
    }
  }

  expect_failures = [var.managed_identities]
}

run "search_connection_needs_the_system_assigned_identity" {
  command = plan

  variables {
    create_project = true
    managed_identities = {
      system_assigned            = false
      user_assigned_resource_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test"]
    }
    project_connections = {
      azure_ai_search = {
        resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Search/searchServices/srch-test"
        endpoint    = "https://srch-test.search.windows.net"
        location    = "uksouth"
      }
    }
  }

  expect_failures = [var.managed_identities]
}

run "project_defaults_to_the_system_assigned_identity" {
  command = plan

  variables {
    create_project = true
  }

  assert {
    condition     = azurerm_cognitive_account_project.this[0].identity[0].type == "SystemAssigned"
    error_message = "The project must keep only the system-assigned identity by default."
  }
}

run "project_accepts_a_user_assigned_identity_next_to_the_system_one" {
  command = plan

  variables {
    create_project = true
    project_managed_identities = {
      user_assigned_resource_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-project"]
    }
  }

  assert {
    condition     = azurerm_cognitive_account_project.this[0].identity[0].type == "SystemAssigned, UserAssigned" && length(azurerm_cognitive_account_project.this[0].identity[0].identity_ids) == 1
    error_message = "The project must carry both identity kinds."
  }
}

run "project_keeps_the_system_assigned_identity" {
  command = plan

  variables {
    create_project = true
    project_managed_identities = {
      system_assigned            = false
      user_assigned_resource_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-project"]
    }
  }

  expect_failures = [var.project_managed_identities]
}

run "project_identity_settings_are_ignored_without_a_project" {
  command = plan

  variables {
    project_managed_identities = {
      system_assigned            = false
      user_assigned_resource_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-project"]
    }
  }

  assert {
    condition     = length(azurerm_cognitive_account_project.this) == 0
    error_message = "No project may be created while create_project is false."
  }
}
