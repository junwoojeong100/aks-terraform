provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable (required since azurerm 4.x).
  # Since azurerm 5.x, automatic Resource Provider registration defaults to "none".
  # Register the required RPs once with the az CLI in Lab 01.
  resource_provider_registrations = "none"

  features {
    resource_group {
      # This setting makes lab cleanup easier. In production, keep the default (true).
      prevent_deletion_if_contains_resources = false
    }
  }
}
