# Plan-only tests for the account network rules.

mock_provider "azurerm" {}
mock_provider "azapi" {}

variables {
  name                                   = "aif-test"
  location                               = "uksouth"
  resource_group_name                    = "rg-test"
  log_analytics_workspace_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test"
  application_insights_connection_string = "InstrumentationKey=00000000-0000-0000-0000-000000000000"
}

run "deny_renders_the_ip_and_subnet_rules" {
  command = plan

  variables {
    network_acls = {
      default_action             = "Deny"
      bypass                     = "AzureServices"
      ip_rules                   = ["203.0.113.0/24"]
      virtual_network_subnet_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-test"]
    }
  }

  assert {
    condition     = azurerm_cognitive_account.this.network_acls[0].default_action == "Deny" && azurerm_cognitive_account.this.network_acls[0].bypass == "AzureServices"
    error_message = "The default action and bypass must reach the account."
  }

  assert {
    condition     = contains(azurerm_cognitive_account.this.network_acls[0].ip_rules, "203.0.113.0/24")
    error_message = "The IP rule must reach the account."
  }

  assert {
    condition     = length(azurerm_cognitive_account.this.network_acls[0].virtual_network_rules) == 1
    error_message = "The subnet rule must reach the account."
  }
}

run "ip_rules_need_a_deny_default_action" {
  command = plan

  variables {
    network_acls = {
      ip_rules = ["203.0.113.0/24"]
    }
  }

  expect_failures = [var.network_acls]
}

run "subnet_rules_need_a_deny_default_action" {
  command = plan

  variables {
    network_acls = {
      virtual_network_subnet_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-test"]
    }
  }

  expect_failures = [var.network_acls]
}

run "unknown_default_action_is_rejected" {
  command = plan

  variables {
    network_acls = {
      default_action = "Block"
    }
  }

  expect_failures = [var.network_acls]
}

run "unknown_bypass_is_rejected" {
  command = plan

  variables {
    network_acls = {
      bypass = "All"
    }
  }

  expect_failures = [var.network_acls]
}

run "rules_have_no_effect_without_public_access" {
  command = plan

  variables {
    public_network_access_enabled = false
    network_acls = {
      default_action = "Deny"
      ip_rules       = ["203.0.113.0/24"]
    }
  }

  expect_failures = [var.public_network_access_enabled]
}

run "public_access_off_needs_no_rules" {
  command = plan

  variables {
    public_network_access_enabled = false
    network_acls = {
      default_action = "Deny"
    }
  }

  assert {
    condition     = azurerm_cognitive_account.this.public_network_access_enabled == false && azurerm_cognitive_account.this.network_acls[0].default_action == "Deny"
    error_message = "Public access must be off with a Deny default action."
  }
}
