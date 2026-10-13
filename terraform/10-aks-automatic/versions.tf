terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "10-aks-automatic.tfstate"
  }
}
