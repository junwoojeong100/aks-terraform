terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "06-workload.tfstate"
  }
}
