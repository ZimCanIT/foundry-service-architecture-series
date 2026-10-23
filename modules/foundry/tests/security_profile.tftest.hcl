# Plan-only tests for the production profile. Each failing run breaks exactly one rule.

mock_provider "azurerm" {}
mock_provider "azapi" {}

variables {
  name                                   = "aif-test"
  location                               = "uksouth"
  resource_group_name                    = "rg-test"
  log_analytics_workspace_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test"
  application_insights_connection_string = "InstrumentationKey=00000000-0000-0000-0000-000000000000"
}

run "baseline_allows_open_public_access" {
  command = plan

  variables {
    security_profile = "baseline"
  }

  assert {
    condition     = azurerm_cognitive_account.this.public_network_access_enabled == true
    error_message = "The baseline profile must keep public access on."
  }
}

run "unknown_profile_is_rejected" {
  command = plan

  variables {
    security_profile = "strict"
  }

  expect_failures = [var.security_profile]
}

run "production_rejects_open_public_access" {
  command = plan

  variables {
    security_profile = "production"
  }

  expect_failures = [azurerm_cognitive_account.this]
}

run "production_accepts_public_access_off" {
  command = plan

  variables {
    security_profile              = "production"
    public_network_access_enabled = false
  }

  assert {
    condition     = azurerm_cognitive_account.this.public_network_access_enabled == false
    error_message = "Public access must be off."
  }
}

run "production_accepts_a_deny_default_action" {
  command = plan

  variables {
    security_profile = "production"
    network_acls = {
      default_action = "Deny"
      ip_rules       = ["203.0.113.0/24"]
    }
  }

  assert {
    condition     = azurerm_cognitive_account.this.network_acls[0].default_action == "Deny"
    error_message = "The Deny default action must reach the account."
  }
}

run "production_rejects_empty_diagnostic_categories" {
  command = plan

  variables {
    security_profile              = "production"
    public_network_access_enabled = false
    diagnostic_log_categories     = []
  }

  expect_failures = [azurerm_cognitive_account.this]
}

run "production_rejects_owner_on_the_account" {
  command = plan

  variables {
    security_profile              = "production"
    public_network_access_enabled = false
    role_assignments = {
      admin = {
        role_definition_name = "Owner"
        principal_id         = "00000000-0000-0000-0000-000000000001"
        principal_type       = "User"
      }
    }
  }

  expect_failures = [azurerm_cognitive_account.this]
}

run "production_accepts_a_foundry_role" {
  command = plan

  variables {
    security_profile              = "production"
    public_network_access_enabled = false
    role_assignments = {
      builders = {
        role_definition_name = "Foundry User"
        principal_id         = "00000000-0000-0000-0000-000000000002"
        principal_type       = "Group"
      }
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.account) == 1
    error_message = "The role assignment must be planned."
  }
}

run "baseline_allows_a_broad_role" {
  command = plan

  variables {
    role_assignments = {
      admin = {
        role_definition_name = "Contributor"
        principal_id         = "00000000-0000-0000-0000-000000000001"
        principal_type       = "User"
      }
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.account) == 1
    error_message = "The baseline profile must not restrict role assignments."
  }
}
