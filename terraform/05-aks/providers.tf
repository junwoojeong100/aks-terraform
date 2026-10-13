provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# AzAPI likewise uses ARM_SUBSCRIPTION_ID and the Azure CLI sign-in as is.
provider "azapi" {}
