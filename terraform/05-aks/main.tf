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

# ---------------------------------------------------------------------------
# Look up the outputs of the earlier stacks (03-network, 04-platform) by naming convention
# ---------------------------------------------------------------------------
data "azurerm_subnet" "aks_nodes" {
  name                 = module.naming.names.snet_aks_nodes
  virtual_network_name = module.naming.names.vnet
  resource_group_name  = module.naming.names.rg_network
}

data "azurerm_subnet" "aks_apiserver" {
  name                 = module.naming.names.snet_aks_apiserver
  virtual_network_name = module.naming.names.vnet
  resource_group_name  = module.naming.names.rg_network
}

data "azurerm_user_assigned_identity" "cluster" {
  name                = module.naming.names.id_aks_cluster
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_user_assigned_identity" "kubelet" {
  name                = module.naming.names.id_aks_kubelet
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_log_analytics_workspace" "this" {
  name                = module.naming.names.log_analytics
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_monitor_workspace" "this" {
  name                = module.naming.names.monitor_workspace
  resource_group_name = module.naming.names.rg_platform
}

# List of GA Kubernetes versions supported in the region (same information as az aks get-versions)
data "azurerm_kubernetes_service_versions" "current" {
  location        = var.location
  include_preview = false
}

# A check block is a "warning-only validation" that does not block apply. An unsupported version is reported at plan time.
check "kubernetes_version_is_supported" {
  assert {
    condition = anytrue([
      for v in data.azurerm_kubernetes_service_versions.current.versions :
      v == var.kubernetes_version || startswith(v, "${var.kubernetes_version}.")
    ])
    error_message = "kubernetes_version=${var.kubernetes_version} is not a supported GA version in ${var.location}. Supported versions: ${join(", ", data.azurerm_kubernetes_service_versions.current.versions)}"
  }
}

# ---------------------------------------------------------------------------
# Cluster resource group (the node resource group 'rg-...-aks-nodes' is created and managed separately by AKS)
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "aks" {
  name     = module.naming.names.rg_aks
  location = var.location
  tags     = local.tags
}
