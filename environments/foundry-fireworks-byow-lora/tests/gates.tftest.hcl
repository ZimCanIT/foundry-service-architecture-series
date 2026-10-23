# Plan-only tests for the gates in front of the Global Provisioned deployments. Each run sets one
# input that should stop the plan, and names the block that must fail. Every other input is valid,
# so a run fails only for the reason it names.

mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "random" {}

override_module {
  target = module.foundry
  outputs = {
    account_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-byow-lora-uat-uks-001/providers/Microsoft.CognitiveServices/accounts/aif-byow-lora-uat-uks-001-abcde"
    account_name                  = "aif-byow-lora-uat-uks-001-abcde"
    account_endpoint              = "https://aif-byow-lora-uat-uks-001-abcde.cognitiveservices.azure.com/"
    project_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-byow-lora-uat-uks-001/providers/Microsoft.CognitiveServices/accounts/aif-byow-lora-uat-uks-001-abcde/projects/proj-byow-lora-uat-uks-001"
    project_name                  = "proj-byow-lora-uat-uks-001"
    project_endpoint              = "https://aif-byow-lora-uat-uks-001-abcde.services.ai.azure.com/api/projects/proj-byow-lora-uat-uks-001"
    project_identity_principal_id = "44444444-4444-4444-4444-444444444444"
  }
}

override_module {
  target = module.azure_monitor
  outputs = {
    log_analytics_workspace_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-byow-lora-uat-uks-001/providers/Microsoft.OperationalInsights/workspaces/log-byow-lora-uat-uks-001"
    log_analytics_workspace_customer_id    = "55555555-5555-5555-5555-555555555555"
    application_insights_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-byow-lora-uat-uks-001/providers/Microsoft.Insights/components/appi-byow-lora-uat-uks-001"
    application_insights_connection_string = "InstrumentationKey=66666666-6666-6666-6666-666666666666"
  }
}

override_data {
  target = data.azurerm_client_config.current
  values = {
    object_id = "22222222-2222-2222-2222-222222222222"
  }
}

variables {
  subscription_id     = "00000000-0000-0000-0000-000000000000"
  tenant_id           = "11111111-1111-1111-1111-111111111111"
  workload_name       = "byow-lora"
  business_unit       = "Training"
  data_classification = "Internal"
  criticality         = "Low"
  service_level       = "Standard"
  support_group       = "Platform operations"
  department          = "Engineering"
  resource_group_name = "rg-byow-lora-uat-uks-001"
  location            = "uksouth"
  region_code         = "uks"
  instance            = "001"
  environment         = "uat"
  owner               = "Platform team"
  ops_team            = "Platform operations"
  project             = "byow-lora"
  managed_by          = "terraform"

  budget = {
    amount                = 100
    start_date            = "2026-11-01T00:00:00Z"
    alert_email_addresses = ["name@example.com"]
  }

  # A valid single adapter and gate, so each run changes only the input it names.
  adapters = {
    deploy-a = {
      model_name    = "custom-model-a"
      model_version = "1"
      ptu_capacity  = 50
    }
  }

  ptu_gate = {
    approved  = true
    approver  = "platform-approver"
    cap       = 50
    minimum   = 25
    increment = 25
  }
}

run "feature_not_registered" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "NotRegistered"
        }
      }
    }
  }

  expect_failures = [
    azapi_resource.byow_deployment,
  ]
}

run "placeholder_model_name" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  variables {
    adapters = {
      deploy-a = {
        model_name    = "REPLACE_WITH_REGISTERED_NAME"
        model_version = "1"
        ptu_capacity  = 50
      }
    }
  }

  expect_failures = [
    azapi_resource.byow_deployment,
  ]
}

run "not_approved" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  variables {
    ptu_gate = {
      approved  = false
      approver  = "platform-approver"
      cap       = 50
      minimum   = 25
      increment = 25
    }
  }

  expect_failures = [
    azapi_resource.byow_deployment,
  ]
}

run "approver_missing" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  variables {
    ptu_gate = {
      approved  = true
      approver  = ""
      cap       = 50
      minimum   = 25
      increment = 25
    }
  }

  expect_failures = [
    azapi_resource.byow_deployment,
  ]
}

run "cap_unset" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  variables {
    ptu_gate = {
      approved  = true
      approver  = "platform-approver"
      cap       = 0
      minimum   = 25
      increment = 25
    }
  }

  expect_failures = [
    azapi_resource.byow_deployment,
  ]
}

run "cap_exceeded" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  variables {
    ptu_gate = {
      approved  = true
      approver  = "platform-approver"
      cap       = 40
      minimum   = 25
      increment = 25
    }
  }

  expect_failures = [
    azapi_resource.byow_deployment,
  ]
}

run "duplicate_model" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  variables {
    adapters = {
      deploy-a = {
        model_name    = "custom-model-a"
        model_version = "1"
        ptu_capacity  = 25
      }
      deploy-b = {
        model_name    = "custom-model-a"
        model_version = "1"
        ptu_capacity  = 25
      }
    }

    ptu_gate = {
      approved  = true
      approver  = "platform-approver"
      cap       = 100
      minimum   = 25
      increment = 25
    }
  }

  expect_failures = [
    azapi_resource.byow_deployment,
  ]
}

run "grid_unset" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  # The minimum and increment are copied from the portal, so leaving them out is a warning.
  variables {
    ptu_gate = {
      approved = true
      approver = "platform-approver"
      cap      = 50
    }
  }

  expect_failures = [
    check.ptu_grid,
  ]
}

run "off_grid" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  # 30 is not the minimum of 25 plus whole increments of 25.
  variables {
    adapters = {
      deploy-a = {
        model_name    = "custom-model-a"
        model_version = "1"
        ptu_capacity  = 30
      }
    }
  }

  expect_failures = [
    check.ptu_grid,
  ]
}

run "bad_principal_type" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  variables {
    inference_principals = {
      caller = {
        principal_id   = "33333333-3333-3333-3333-333333333333"
        principal_type = "Foreign"
      }
    }
  }

  expect_failures = [
    var.inference_principals,
  ]
}

run "bad_deployment_name" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  variables {
    adapters = {
      "deploy a" = {
        model_name    = "custom-model-a"
        model_version = "1"
        ptu_capacity  = 50
      }
    }
  }

  expect_failures = [
    var.adapters,
  ]
}

run "budget_start_not_first_of_month" {
  command = plan

  override_data {
    target = data.azapi_resource.fireworks_feature
    values = {
      exists = true
      output = {
        properties = {
          state = "Registered"
        }
      }
    }
  }

  variables {
    budget = {
      amount                = 100
      start_date            = "2026-11-15T00:00:00Z"
      alert_email_addresses = ["name@example.com"]
    }
  }

  expect_failures = [
    var.budget,
  ]
}
