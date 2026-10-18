terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.8.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13.0"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  use_cli         = true

  # Fireworks deployments need Microsoft.CognitiveServices, which is not in the
  # provider's default registration set.
  resource_providers_to_register = ["Microsoft.CognitiveServices"]

  features {
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      # The group is dedicated to this environment, and Azure adds resources that
      # Terraform does not track, such as the alert rule generated for Application
      # Insights. Allow destroy to delete them with the group.
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  use_cli         = true
}
