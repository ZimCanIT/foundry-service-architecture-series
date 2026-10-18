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
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "azurerm" {
  use_cli = true

  features {
    resource_group {
      # The group is dedicated to this environment, and Azure adds resources that
      # Terraform does not track, such as the alert rule generated for Application
      # Insights. Allow destroy to delete them with the group.
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azapi" {
  use_cli = true
}
