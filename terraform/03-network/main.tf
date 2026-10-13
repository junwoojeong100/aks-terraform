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

  # StandardV2 NAT Gateway / Public IP 는 기본적으로 zone-redundant 이므로 zones 를 지정하지 않습니다.
  nat_zones = var.nat_gateway_sku == "StandardV2" ? null : ["1"]

  # Private Endpoint 용 Private DNS Zone. 새 PaaS 를 추가하면 여기에 한 줄만 추가하면 됩니다.
  private_dns_zones = {
    acr       = "privatelink.azurecr.io"
    key_vault = "privatelink.vaultcore.azure.net"
  }

  # 같은 출발지를 두 번 적어도 NSG 규칙에는 한 번만 들어가도록 중복을 제거합니다.
  gateway_sources = distinct(var.gateway_allowed_source_prefixes)
}

# ---------------------------------------------------------------------------
# Resource group + VNet
# AWS 의 VPC 는 리전 단위이고 서브넷이 AZ 에 묶이지만,
# Azure VNet 의 서브넷은 리전 전체에 걸쳐 있고 AZ 는 VM/노드 단위로 지정합니다.
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "network" {
  name     = module.naming.names.rg_network
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = module.naming.names.vnet
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  address_space       = [var.address_space]
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Subnets
# default_outbound_access_enabled = false : "기본 아웃바운드 IP" 에 의존하지 않고
# NAT Gateway 로만 인터넷에 나가는 private subnet 으로 만듭니다.
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "aks_nodes" {
  name                            = module.naming.names.snet_aks_nodes
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.aks_nodes]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "aks_apiserver" {
  name                            = module.naming.names.snet_aks_apiserver
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.aks_apiserver]
  default_outbound_access_enabled = false

  # API Server VNet Integration: AKS 컨트롤 플레인의 API 서버가 이 서브넷에 투영됩니다.
  delegation {
    name = "aks-apiserver"

    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "ingress" {
  name                            = module.naming.names.snet_ingress
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.ingress]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "private_endpoints" {
  name                            = module.naming.names.snet_private_endpoint
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.private_endpoints]
  default_outbound_access_enabled = false

  # Private Endpoint 에도 NSG 규칙을 적용합니다 (기본값은 Disabled).
  private_endpoint_network_policies = "Enabled"
}

# ---------------------------------------------------------------------------
# NSG (AWS 의 Security Group + NACL 역할을 겸함)
# - 상태 저장(stateful), 서브넷/NIC 에 연결, 우선순위 숫자가 낮을수록 먼저 평가, Allow/Deny 모두 가능
# - AKS 는 "내가 서브넷에 연결한 NSG" 를 수정하지 않습니다. Service(LoadBalancer) 용 규칙도 자동으로 추가되지 않으므로
#   노드 서브넷에 필요한 인바운드 허용 규칙은 아래에서 Terraform 으로 직접 정의합니다.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "aks_nodes" {
  name                = module.naming.names.nsg_aks_nodes
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

# snet-ingress 에는 내부 LB 프런트엔드 IP 만 있고 VM(NIC)이 없습니다. 내부 Gateway 로 들어오는 트래픽은
# 백엔드인 노드 서브넷의 NSG 가 평가하므로 이 NSG 에는 규칙을 두지 않습니다.
resource "azurerm_network_security_group" "ingress" {
  name                = module.naming.names.nsg_ingress
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = module.naming.names.nsg_private_endpoint
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

# Private Endpoint 서브넷은 "AKS 노드 서브넷의 HTTPS" 만 허용하고 나머지 VNet 내부 트래픽은 차단합니다.
# (기본 규칙 AllowVnetInBound 가 65000 이므로 4000 번 Deny 로 먼저 막습니다.)
resource "azurerm_network_security_rule" "pe_allow_aks_nodes" {
  name                        = "AllowAksNodesHttps"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.subnet_cidrs.aks_nodes
  destination_address_prefix  = var.subnet_cidrs.private_endpoints
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

resource "azurerm_network_security_rule" "pe_deny_vnet" {
  name                        = "DenyOtherVnetInbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

# ---------------------------------------------------------------------------
# 노드 서브넷 NSG 인바운드 허용 규칙 (우선순위: 100번대 = 클러스터 내부 통신, 200번대 = Gateway)
#
# 기본 규칙만으로 통과하는 것 (실측: 규칙을 지워도 막히지 않음)
#   - 노드 ↔ 노드, API 서버 서브넷 → 노드(kubelet 10250), VNet 안의 클라이언트 → 내부 Gateway : AllowVnetInBound (65000)
#   - Azure Load Balancer 상태 프로브                                                      : AllowAzureLoadBalancerInBound (65001)
#   - Azure CNI Overlay 의 노드 → Pod, Pod ↔ Pod (DNS 포함)                                 : 기본 규칙으로 통과
#
# 직접 허용해야 하는 것 (필수)
#   - 공용 Gateway: Standard LB 는 인바운드가 기본적으로 닫혀 있어 NSG 에서 허용해야 합니다 (AllowGatewayHttpHttps).
#
# 미리 허용해 두는 것 (방어용)
#   - Overlay 의 Pod 트래픽은 캡슐화되지 않아 서브넷 NSG 가 그대로 적용됩니다. 지금은 기본 규칙이 허용하지만, 나중에 조직 정책이나
#     하드닝으로 Deny 규칙(예: 4000 번 DenyAllInBound)을 더하면 노드 간 Pod 통신과 DNS 가 끊깁니다 (실측: Deny 를 더하면 타임아웃,
#     아래 허용 규칙이 있으면 통과). AKS 문서가 요구하는 허용 규칙(노드 → Pod, Pod → Pod)을 미리 만들어 둡니다.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_rule" "nodes_allow_nodes_to_pods" {
  name                        = "AllowNodesToPods"
  description                 = "Service 트래픽 라우팅: 노드 -> Pod (Azure CNI Overlay)"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.subnet_cidrs.aks_nodes
  destination_address_prefix  = var.pod_cidr
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.aks_nodes.name
}

resource "azurerm_network_security_rule" "nodes_allow_pods_to_pods" {
  name                        = "AllowPodsToPods"
  description                 = "Pod 간, Pod -> Service 트래픽(DNS 포함) (Azure CNI Overlay)"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.pod_cidr
  destination_address_prefix  = var.pod_cidr
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.aks_nodes.name
}

# API Server VNet Integration: API 서버(위임 서브넷)에서 노드로 들어오는 트래픽 (kubectl exec · logs · port-forward 는 kubelet 10250 으로 갑니다).
# 기본 규칙(AllowVnetInBound)으로도 통과하지만 나중에 Deny 규칙을 더하면 끊깁니다 (실측: Deny 를 더하면 exec 가 connection reset,
# 이 규칙이 있으면 통과). Pod CIDR 대상은 웹훅 호출 경로에서는 필요가 확인되지 않아 방어적으로만 둡니다.
resource "azurerm_network_security_rule" "nodes_allow_apiserver" {
  name                         = "AllowApiServerToCluster"
  description                  = "API 서버 -> 노드(kubelet 10250: exec, logs), Pod. Deny 를 더해도 kubectl exec 가 끊기지 않게"
  priority                     = 120
  direction                    = "Inbound"
  access                       = "Allow"
  protocol                     = "*"
  source_port_range            = "*"
  destination_port_range       = "*"
  source_address_prefix        = var.subnet_cidrs.aks_apiserver
  destination_address_prefixes = [var.subnet_cidrs.aks_nodes, var.pod_cidr]
  resource_group_name          = azurerm_resource_group.network.name
  network_security_group_name  = azurerm_network_security_group.aks_nodes.name
}

# 공용 Gateway(Standard LB): 허용한 출발지 → HTTP/HTTPS 리스너.
# 공용 LB 의 공인 IP 는 AKS 가 나중에 만들어 plan 시점에는 알 수 없고, 노드에는 공인 IP 가 없어 LB 가 80/443 으로 연 서비스(Gateway)만
# 인터넷에서 닿습니다. 그래서 목적지는 * 로 둡니다. (443 은 Lab 07 의 TLS 리스너를 추가할 때 NSG 를 다시 고치지 않게 미리 허용)
# 출발지 값이 1개면 단수, 여러 개면 복수 속성에 담습니다 (둘 중 하나만 지정 가능, 서비스 태그는 단수에만 쓸 수 있음).
# gateway_allowed_source_prefixes = [] 이면 규칙을 만들지 않습니다 (내부 Gateway 전용).
resource "azurerm_network_security_rule" "nodes_allow_gateway" {
  count = length(local.gateway_sources) > 0 ? 1 : 0

  name                        = "AllowGatewayHttpHttps"
  description                 = "공용 Gateway(Standard LB) 인바운드 HTTP/HTTPS"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80", "443"]
  source_address_prefix       = length(local.gateway_sources) == 1 ? local.gateway_sources[0] : null
  source_address_prefixes     = length(local.gateway_sources) > 1 ? local.gateway_sources : null
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.aks_nodes.name
}

resource "azurerm_subnet_network_security_group_association" "aks_nodes" {
  subnet_id                 = azurerm_subnet.aks_nodes.id
  network_security_group_id = azurerm_network_security_group.aks_nodes.id
}

resource "azurerm_subnet_network_security_group_association" "ingress" {
  subnet_id                 = azurerm_subnet.ingress.id
  network_security_group_id = azurerm_network_security_group.ingress.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# ---------------------------------------------------------------------------
# NAT Gateway : 노드의 아웃바운드(인터넷) 트래픽을 고정 공인 IP 로 내보냅니다.
# AWS 의 "private subnet + NAT Gateway" 와 같은 구조이며, Azure 는 서브넷에 직접 연결합니다.
# (라우트 테이블 수정이 필요 없습니다.)
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  name                = module.naming.names.pip_nat_gateway
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  allocation_method   = "Static"
  sku                 = var.nat_gateway_sku
  zones               = local.nat_zones
  tags                = local.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = module.naming.names.nat_gateway
  location                = azurerm_resource_group.network.location
  resource_group_name     = azurerm_resource_group.network.name
  sku_name                = var.nat_gateway_sku
  zones                   = local.nat_zones
  idle_timeout_in_minutes = 4
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "aks_nodes" {
  subnet_id      = azurerm_subnet.aks_nodes.id
  nat_gateway_id = azurerm_nat_gateway.this.id

  depends_on = [azurerm_nat_gateway_public_ip_association.this]
}

# ---------------------------------------------------------------------------
# Private DNS Zone : Private Endpoint 의 FQDN 을 사설 IP 로 해석합니다.
# AWS 의 Interface VPC Endpoint 는 "Private DNS 활성화" 한 번이면 끝나지만,
# Azure 는 Zone 생성 → VNet 링크 → (Private Endpoint 쪽) DNS Zone Group 연결 을 직접 구성합니다.
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "this" {
  for_each = local.private_dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.private_dns_zones

  name                 = "link-${azurerm_virtual_network.this.name}"
  private_dns_zone_id  = azurerm_private_dns_zone.this[each.key].id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = local.tags
}
