terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  # storage_account_name / container_name 은 `terraform init -backend-config=../backend.hcl` 로 주입합니다.
  backend "azurerm" {
    use_azuread_auth = true
    key              = "03-network.tfstate"
  }
}
