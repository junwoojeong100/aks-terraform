terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  # The bootstrap stack starts with local state (it creates the state storage itself: a "chicken-and-egg" problem).
  # In the last step of Lab 02, uncomment the block below and migrate state with
  # `terraform init -migrate-state -backend-config=../backend.hcl`.
  #
  # backend "azurerm" {
  #   use_azuread_auth = true
  #   key              = "02-bootstrap.tfstate"
  # }
}
