data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

locals {
  byo = var.use_byo_network

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

resource "azurerm_resource_group" "automatic" {
  name     = module.naming.names.rg_automatic
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# (Optional) BYO VNet : created only when use_byo_network = true
# Same layout as the official Microsoft sample (101-aks-automatic-custom-network).
#   - API server subnet : delegated to Microsoft.ContainerService/managedClusters (/28 or larger)
#   - User node subnet  : where the nodes created by NAP are placed
#   - System node subnet: for the system node pool managed by AKS
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "byo" {
  count = local.byo ? 1 : 0

  name                = module.naming.names.vnet_automatic
  location            = azurerm_resource_group.automatic.location
  resource_group_name = azurerm_resource_group.automatic.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "api_server" {
  count = local.byo ? 1 : 0

  name                 = "snet-apiserver"
  resource_group_name  = azurerm_resource_group.automatic.name
  virtual_network_name = azurerm_virtual_network.byo[0].name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 12, 0)] # /28

  delegation {
    name = "aks-delegation"

    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "user_nodes" {
  count = local.byo ? 1 : 0

  name                 = "snet-user-nodes"
  resource_group_name  = azurerm_resource_group.automatic.name
  virtual_network_name = azurerm_virtual_network.byo[0].name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 1)] # /24
}

resource "azurerm_subnet" "system_nodes" {
  count = local.byo ? 1 : 0

  name                 = "snet-system-nodes"
  resource_group_name  = azurerm_resource_group.automatic.name
  virtual_network_name = azurerm_virtual_network.byo[0].name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 2)] # /24

  lifecycle {
    # After the cluster is created, AKS adds a delegation to this subnet.
    ignore_changes = [delegation]
  }
}

resource "azurerm_user_assigned_identity" "aks" {
  count = local.byo ? 1 : 0

  name                = module.naming.names.id_aks_automatic
  location            = azurerm_resource_group.automatic.location
  resource_group_name = azurerm_resource_group.automatic.name
  tags                = local.tags
}

# Network Contributor so the cluster identity can join subnets and create NAP nodes inside the VNet
resource "azurerm_role_assignment" "network_contributor" {
  count = local.byo ? 1 : 0

  scope                = azurerm_virtual_network.byo[0].id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks[0].principal_id
  principal_type       = "ServicePrincipal"
}
