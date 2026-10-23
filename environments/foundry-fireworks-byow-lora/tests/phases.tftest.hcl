# Plan-only tests for the two phases of the root. Every provider is mocked and both modules are
# overridden, so nothing here reaches Azure and no credentials are needed.

mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "random" {}

# Outputs of the modules, with well-formed ARM IDs so the mocked providers accept them.
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
}

run "phase1_without_adapters" {
  command = plan

  variables {
    adapters = {}
  }

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

  assert {
    condition     = length(azapi_resource.byow_deployment) == 0
    error_message = "Phase 1 must create no deployment instance."
  }

  assert {
    condition     = output.ptu_total == 0
    error_message = "Phase 1 must request no Global Provisioned capacity."
  }
}

run "phase2_one_adapter" {
  command = plan

  variables {
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

  assert {
    condition     = length(azapi_resource.byow_deployment) == 1
    error_message = "One adapter must create one deployment instance."
  }

  assert {
    condition     = azapi_resource.byow_deployment["deploy-a"].body.properties.model.format == "FireworksCustom"
    error_message = "The deployment model format must be FireworksCustom."
  }

  assert {
    condition     = azapi_resource.byow_deployment["deploy-a"].body.properties.model.source == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-byow-lora-uat-uks-001/providers/Microsoft.CognitiveServices/accounts/aif-byow-lora-uat-uks-001-abcde/projects/proj-byow-lora-uat-uks-001"
    error_message = "The deployment source must be the Foundry project ID."
  }

  assert {
    condition     = azapi_resource.byow_deployment["deploy-a"].body.sku.name == "GlobalProvisionedManaged"
    error_message = "The deployment SKU must be GlobalProvisionedManaged."
  }

  assert {
    condition     = azapi_resource.byow_deployment["deploy-a"].body.sku.capacity == 50
    error_message = "The deployment capacity must match ptu_capacity."
  }
}

run "two_adapters" {
  command = plan

  variables {
    adapters = {
      deploy-a = {
        model_name    = "custom-model-a"
        model_version = "1"
        ptu_capacity  = 50
      }
      deploy-b = {
        model_name    = "custom-model-b"
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

  assert {
    condition     = length(azapi_resource.byow_deployment) == 2
    error_message = "Two adapters must create two deployment instances."
  }

  assert {
    condition     = output.ptu_total == 75
    error_message = "The total capacity must be the sum of both adapters."
  }
}
