terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  # storage_account_name / container_name are injected with `terraform init -backend-config=../backend.hcl`.
  backend "azurerm" {
    use_azuread_auth = true
    key              = "03-network.tfstate"
  }
}
