terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.13.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.8.0"
    }
  }
}
