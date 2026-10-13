terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }

    # New AKS features that azurerm doesn't support yet (Gateway API, control plane metrics) are enabled through AzAPI.
    # (Similar to using the awscc provider on AWS for new APIs that the aws provider hasn't caught up with.)
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "05-aks.tfstate"
  }
}
