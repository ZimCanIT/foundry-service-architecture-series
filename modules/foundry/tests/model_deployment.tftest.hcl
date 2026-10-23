# Plan-only tests for the optional model deployment. The model name and version are fixtures,
# not claims about what Azure offers. The SKU must be one that the provider schema accepts.

mock_provider "azurerm" {}
mock_provider "azapi" {}

variables {
  name                                   = "aif-test"
  location                               = "uksouth"
  resource_group_name                    = "rg-test"
  log_analytics_workspace_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test"
  application_insights_connection_string = "InstrumentationKey=00000000-0000-0000-0000-000000000000"
}

run "valid_deployment_is_pinned_and_described" {
  command = plan

  variables {
    model_deployment = {
      name          = "example"
      model_name    = "example-model"
      model_version = "2000-01-01"
      sku_name      = "Standard"
      capacity      = 10
    }
  }

  assert {
    condition     = length(azurerm_cognitive_deployment.model) == 1 && azurerm_cognitive_deployment.model[0].version_upgrade_option == "NoAutoUpgrade"
    error_message = "The deployment must be created and stay on NoAutoUpgrade by default."
  }

  assert {
    condition     = output.model_deployment_metadata.model_name == "example-model" && output.model_deployment_metadata.model_version == "2000-01-01" && output.model_deployment_metadata.sku_name == "Standard" && output.model_deployment_metadata.capacity == 10
    error_message = "model_deployment_metadata must describe the deployment that was asked for."
  }

  assert {
    condition     = output.model_deployment_metadata.version_upgrade_option == "NoAutoUpgrade" && output.model_deployment_name == "example"
    error_message = "model_deployment_metadata and model_deployment_name must agree with the deployment."
  }
}

run "zero_capacity_is_rejected" {
  command = plan

  variables {
    model_deployment = {
      name          = "example"
      model_name    = "example-model"
      model_version = "2000-01-01"
      sku_name      = "Standard"
      capacity      = 0
    }
  }

  expect_failures = [var.model_deployment]
}

run "fractional_capacity_is_rejected" {
  command = plan

  variables {
    model_deployment = {
      name          = "example"
      model_name    = "example-model"
      model_version = "2000-01-01"
      sku_name      = "Standard"
      capacity      = 1.5
    }
  }

  expect_failures = [var.model_deployment]
}

run "unknown_upgrade_option_is_rejected" {
  command = plan

  variables {
    model_deployment = {
      name                   = "example"
      model_name             = "example-model"
      model_version          = "2000-01-01"
      sku_name               = "Standard"
      capacity               = 10
      version_upgrade_option = "Always"
    }
  }

  expect_failures = [var.model_deployment]
}

run "no_auto_upgrade_needs_a_version" {
  command = plan

  variables {
    model_deployment = {
      name          = "example"
      model_name    = "example-model"
      model_version = ""
      sku_name      = "Standard"
      capacity      = 10
    }
  }

  expect_failures = [var.model_deployment]
}

run "auto_upgrade_allows_an_empty_version" {
  command = plan

  variables {
    model_deployment = {
      name                   = "example"
      model_name             = "example-model"
      model_version          = ""
      sku_name               = "Standard"
      capacity               = 10
      version_upgrade_option = "OnceNewDefaultVersionAvailable"
    }
  }

  assert {
    condition     = length(azurerm_cognitive_deployment.model) == 1
    error_message = "An auto-upgrading deployment may leave the version empty."
  }
}

run "sku_name_with_a_space_is_rejected" {
  command = plan

  variables {
    model_deployment = {
      name          = "example"
      model_name    = "example-model"
      model_version = "2000-01-01"
      sku_name      = "Example Sku"
      capacity      = 10
    }
  }

  expect_failures = [var.model_deployment]
}

run "empty_sku_name_is_rejected" {
  command = plan

  variables {
    model_deployment = {
      name          = "example"
      model_name    = "example-model"
      model_version = "2000-01-01"
      sku_name      = ""
      capacity      = 10
    }
  }

  expect_failures = [var.model_deployment]
}
