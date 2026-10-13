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

  # Key Vault IP rules do not accept /31 or /32 prefixes, so they are converted to single IPs.
  key_vault_ip_rules = [for cidr in var.allowed_ip_ranges : replace(cidr, "/32", "")]
}

# ---------------------------------------------------------------------------
# Look up the resources created by the 03-network stack by "naming convention".
# Works like AWS `data "aws_vpc"` + tag lookups, and has no remote state dependency.
# ---------------------------------------------------------------------------
data "azurerm_resource_group" "network" {
  name = module.naming.names.rg_network
}

data "azurerm_virtual_network" "this" {
  name                = module.naming.names.vnet
  resource_group_name = module.naming.names.rg_network
}

data "azurerm_subnet" "private_endpoints" {
  name                 = module.naming.names.snet_private_endpoint
  virtual_network_name = module.naming.names.vnet
  resource_group_name  = module.naming.names.rg_network
}

data "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = module.naming.names.rg_network
}

data "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = module.naming.names.rg_network
}

# ---------------------------------------------------------------------------
# Platform (shared services) resource group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "platform" {
  name     = module.naming.names.rg_platform
  location = var.location
  tags     = local.tags
}
