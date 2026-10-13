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
# (선택) BYO VNet : use_byo_network = true 일 때만 생성
# Microsoft 공식 샘플(101-aks-automatic-custom-network)과 같은 구성입니다.
#   - API 서버 서브넷  : Microsoft.ContainerService/managedClusters 로 위임 (/28 이상)
#   - User 노드 서브넷 : NAP 가 만드는 노드가 위치
#   - System 노드 서브넷: AKS 가 관리하는 시스템 노드 풀(managed system node pool)용
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
    # 클러스터 생성 후 AKS 가 이 서브넷에 위임(delegation)을 추가합니다.
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

# 클러스터 ID 가 VNet 안에서 서브넷 join / NAP 노드 생성을 할 수 있도록 Network Contributor
resource "azurerm_role_assignment" "network_contributor" {
  count = local.byo ? 1 : 0

  scope                = azurerm_virtual_network.byo[0].id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks[0].principal_id
  principal_type       = "ServicePrincipal"
}
