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

  app_name = "kv-demo"
  app_image = (
    var.app_image != "" ? var.app_image : "${data.azurerm_container_registry.this.login_server}/demo/busybox:2.0"
  )
}

# Look up the resources created by earlier stacks by naming convention
data "azurerm_kubernetes_cluster" "this" {
  name                = module.naming.names.aks
  resource_group_name = module.naming.names.rg_aks
}

data "azurerm_key_vault" "this" {
  name                = module.naming.names.key_vault
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_container_registry" "this" {
  name                = module.naming.names.acr
  resource_group_name = module.naming.names.rg_platform
}

resource "azurerm_resource_group" "workload" {
  name     = module.naming.names.rg_workload
  location = var.location
  tags     = local.tags
}
