data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

data "azurerm_resource_group" "aks" {
  name = module.naming.names.rg_aks
}

data "azurerm_resource_group" "network" {
  name = module.naming.names.rg_network
}

data "azurerm_resource_group" "platform" {
  name = module.naming.names.rg_platform
}
