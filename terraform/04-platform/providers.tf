provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }

    key_vault {
      # If a soft-deleted Key Vault with the same name exists, recover it instead of creating a new one.
      recover_soft_deleted_key_vaults = true
      purge_soft_delete_on_destroy    = false
    }

    log_analytics_workspace {
      # Permanently delete on destroy so the same name can be reused after the lab.
      permanently_delete_on_destroy = true
    }
  }
}
