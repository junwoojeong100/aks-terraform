data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

locals {
  app_name = "aspnetapp"
  app_image = (
    var.app_image != "" ? var.app_image : "${data.azurerm_container_registry.this.login_server}/demo/aspnetapp:v1"
  )
}

data "azurerm_kubernetes_cluster" "this" {
  name                = module.naming.names.aks
  resource_group_name = module.naming.names.rg_aks
}

data "azurerm_container_registry" "this" {
  name                = module.naming.names.acr
  resource_group_name = module.naming.names.rg_platform
}
