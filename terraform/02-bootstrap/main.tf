data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

locals {
  tags = merge(
    {
      workload    = var.workload
      environment = var.environment
      managed_by  = "terraform"
      lab         = "aks-terraform-guide"
    },
    var.tags,
  )
}

resource "azurerm_resource_group" "tfstate" {
  name     = module.naming.names.rg_tfstate
  location = var.location
  tags     = local.tags
}

# Equivalent to an S3 bucket + (DynamoDB lock table).
# The Azure Blob backend provides state locking through blob leases, so no separate lock table is needed.
resource "azurerm_storage_account" "tfstate" {
  name                = module.naming.names.st_tfstate
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "ZRS" # Synchronous replication across 3 availability zones (like S3's default multi-AZ durability)

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false # S3 Block Public Access
  shared_access_key_enabled       = false # Disable account keys → allow Entra ID (RBAC) authentication only
  default_to_oauth_authentication = true

  blob_properties {
    versioning_enabled = true # S3 Versioning: lets you restore a previous version after a bad state overwrite.

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# Grant the signed-in user (or the CI service principal) read/write access to state.
# Uses an Azure RBAC role assignment instead of an IAM policy (s3:GetObject/PutObject).
resource "azurerm_role_assignment" "state_contributor" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
