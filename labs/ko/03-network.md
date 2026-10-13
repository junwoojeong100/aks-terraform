<!-- lang-switch -->
[English](../03-network.md) | **한국어**
<!-- /lang-switch -->

# Lab 03. 네트워크: VNet · NSG · NAT Gateway · Private DNS

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 20분 | NAT Gateway + Public IP (시간당 소액) | `terraform/03-network` | [02. 원격 State](02-bootstrap.md) |

## 이번 실습에서 만드는 것

![VNet 설계: 서브넷 · NSG · NAT Gateway · Private DNS](diagrams/network-topology.svg)

텍스트로 요약하면 다음과 같습니다.

```text
Internet
  ▲   고정 공인 IP 1개 (외부 서비스 방화벽 허용 목록용)
  │
NAT Gateway  (StandardV2, 영역 중복)  ── 서브넷 연결 ──►  snet-aks-nodes

VNet 10.10.0.0/16   (rg-…-network)
  ├─ snet-aks-nodes          10.10.0.0/24   AKS 노드 · NSG(Pod · API 서버 · Gateway 인바운드 허용) · NAT Gateway 연결
  ├─ snet-aks-apiserver      10.10.1.0/28   API Server VNet Integration (AKS 전용으로 위임)
  ├─ snet-ingress            10.10.2.0/27   내부 로드밸런서 프런트엔드 IP · NSG
  └─ snet-private-endpoints  10.10.3.0/27   ACR / Key Vault Private Endpoint · NSG (노드 서브넷의 443 만 허용)

Private DNS Zone (VNet 링크):  privatelink.azurecr.io  ·  privatelink.vaultcore.azure.net
```

## AWS 경험자를 위한 비교

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| VPC | `azurerm_virtual_network` | 서브넷 CIDR 은 VNet 주소 공간 안에서 자유롭게. 서브넷마다 Azure 가 **5개 IP** 를 예약(AWS 와 동일). |
| Subnet (AZ 고정) | `azurerm_subnet` | **AZ 와 무관**. 노드 풀/LB 가 AZ 를 지정. |
| Security Group + NACL | `azurerm_network_security_group` | 상태 저장 + 우선순위(낮은 숫자 우선) + Deny. 서브넷에 연결. |
| Private subnet + NAT GW | `azurerm_nat_gateway` + 서브넷 연결 | 라우트 테이블 수정 불필요. `default_outbound_access_enabled = false` 로 "암묵적 인터넷 접속"을 끕니다. |
| Interface VPC Endpoint | `azurerm_private_endpoint` + Private DNS Zone | 다음 Lab 04 에서 ACR/Key Vault 에 연결. |
| Route 53 Private Hosted Zone | `azurerm_private_dns_zone` + `..._virtual_network_link` | VNet 링크가 있어야 해당 VNet 에서 이름이 해석됩니다. |

> [!IMPORTANT]
> **IP 용량 계획**: Azure CNI Overlay 에서는 **노드만** VNet IP 를 씁니다. 노드 서브넷 `/24`(251개)는 업그레이드 시 임시 노드(max_surge 33%)까지 고려해도 수십 대 규모에 충분합니다. 노드 수백 대를 계획한다면 `/22` 이상으로 키우세요. API 서버 서브넷은 클러스터 하나당 `/28` 이 최소이며 **다른 용도로 쓸 수 없습니다**.

## 설계 결정 (Best practice)

| 결정 | 이유 |
|---|---|
| 서브넷을 용도별로 분리 (노드 / API 서버 / 인그레스 / PE) | 서브넷 단위 NSG·위임·IP 계획이 가능. 인그레스 LB IP 를 별도 서브넷에 두면 노드 서브넷 규칙에 영향을 주지 않습니다. |
| `default_outbound_access_enabled = false` | 기본 아웃바운드 IP 는 소유권이 없고 바뀔 수 있어 Azure 가 폐지를 진행 중입니다. 명시적 egress(NAT Gateway)가 권장입니다. |
| NAT Gateway **StandardV2** | 영역 중복(zone-redundant)이며 AKS `userAssignedNATGateway` 와 함께 사용 가능. 일부 리전(Canada East 등)은 미지원 → 변수 `nat_gateway_sku = "Standard"`. |
| PE 서브넷 NSG: **노드 서브넷의 443 만 허용 + 나머지 VNet 내부 Deny** | Private Endpoint 에 NSG 를 적용하려면 `private_endpoint_network_policies = "Enabled"` 가 필요합니다. 최소 권한 네트워크 분리. |
| 노드 서브넷 NSG: **인바운드 허용 규칙을 Terraform 으로 직접 정의** | AKS 는 직접 만들어 서브넷에 연결한 NSG 를 수정하지 않습니다(Service 용 규칙도 자동으로 추가되지 않음). 공용 Gateway 는 이 규칙이 없으면 접속이 안 됩니다. Pod · API 서버 트래픽은 기본 규칙으로도 통과하지만 Deny 규칙을 더하는 순간 끊기므로 허용 규칙을 미리 둡니다(모두 실제 구독에서 확인). 아래 *NSG 인바운드 규칙* 참고. |
| 인그레스 서브넷 NSG 는 **규칙 없음** | 이 서브넷에는 내부 LB 프런트엔드 IP 만 있고 VM(NIC)이 없습니다. 로드밸런서를 거친 트래픽은 백엔드인 노드 서브넷 NSG 가 평가합니다. |
| Private DNS Zone 을 네트워크 스택에서 관리 | 실제 환경에서는 연결(Connectivity) 구독에서 중앙 관리하는 경우가 많습니다. |

## NSG 인바운드 규칙

NSG 는 우선순위 숫자가 낮은 규칙부터 평가하고, 맞는 규칙이 없으면 기본 규칙(`AllowVnetInBound` 65000 → `AllowAzureLoadBalancerInBound` 65001 → `DenyAllInBound` 65500)을 적용합니다. 이 스택의 인바운드 트래픽과 허용 방법은 다음과 같습니다. **구분** 열의 결과는 실제 구독에서 규칙을 지우거나 Deny 규칙을 더해 확인한 값입니다([부록 A](99-appendix.md)).

| NSG | 트래픽 | 규칙 | 구분 |
|---|---|---|---|
| 노드 | 노드 ↔ 노드 · VNet 안의 클라이언트 → 내부 Gateway | 기본 규칙 `AllowVnetInBound` | 기본 규칙으로 통과 |
| 노드 | Azure Load Balancer 상태 프로브 | 기본 규칙 `AllowAzureLoadBalancerInBound` | 기본 규칙으로 통과 |
| 노드 | 인터넷 → 공용 Gateway (HTTP/HTTPS) | `AllowGatewayHttpHttps` (200): `gateway_allowed_source_prefixes`(기본 `Internet`) → TCP 80 · 443 | **필수** — 지우면 접속 불가 |
| 노드 | 노드 → Pod · Pod ↔ Pod (DNS 포함) | `AllowNodesToPods` (100): 노드 CIDR → `pod_cidr` · `AllowPodsToPods` (110): `pod_cidr` → `pod_cidr` | 방어용 — 기본 규칙으로 통과, Deny 를 더하면 끊김 |
| 노드 | API 서버 → 노드(kubelet 10250: `kubectl exec` · logs) · Pod | `AllowApiServerToCluster` (120): API 서버 서브넷 → 노드 CIDR · `pod_cidr` | 방어용 — 기본 규칙으로 통과, Deny 를 더하면 `exec` 가 끊김 |
| Private Endpoint | 노드 → ACR · Key Vault | `AllowAksNodesHttps` (100): 노드 CIDR → TCP 443. 나머지 VNet 트래픽은 `DenyOtherVnetInbound` (4000) 로 거부 | 설계 |
| 인그레스 | 없음 | 규칙을 두지 않습니다 (위 *설계 결정* 참고) | — |

> [!IMPORTANT]
> **AKS 는 직접 만들어 서브넷에 연결한 NSG 를 수정하지 않습니다.** Service(`LoadBalancer`) 용 규칙은 AKS 가 관리하는 리소스에만 자동으로 추가됩니다([AKS 네트워킹 개념](https://learn.microsoft.com/azure/aks/concepts-network#network-security-groups)). 실제로 AKS 는 노드 리소스 그룹에 자체 NSG(`aks-agentpool-…-nsg`)를 만들어 노드 NIC 에 연결하고 `k8s-azure-lb_allow_…` 규칙을 거기에만 추가하며, 우리 서브넷 NSG 는 그대로입니다. 인바운드는 서브넷 NSG 와 NIC NSG 를 모두 통과해야 하므로, 서브넷 NSG 에 허용 규칙이 없으면 공용 Gateway 가 열리지 않습니다.

> [!IMPORTANT]
> **Pod 트래픽도 서브넷 NSG 의 평가 대상입니다.** Azure CNI Overlay 의 Pod 트래픽은 캡슐화되지 않으므로 서브넷 NSG 가 적용됩니다([Azure CNI Overlay: NSG](https://learn.microsoft.com/azure/aks/concepts-network-azure-cni-overlay#network-security-groups)). 기본 규칙만 있을 때는 노드 간 Pod 통신과 DNS 가 그대로 통과하지만, 조직 정책이나 하드닝으로 Deny 규칙(예: 4000 번 Deny)을 더하는 순간 끊깁니다. `AllowNodesToPods` / `AllowPodsToPods` 가 있으면 Deny 가 있어도 통과합니다. 그래서 **`pod_cidr` 는 05-aks 와 같은 값**(기본 `10.244.0.0/16`)이어야 하며, `scripts/verify.sh 05-aks` 가 두 값이 맞는지 확인합니다.

> [!NOTE]
> 공용 Gateway 를 특정 IP 에만 열려면 `-var 'gateway_allowed_source_prefixes=["203.0.113.10/32"]'`, 내부 Gateway 만 쓴다면 `-var 'gateway_allowed_source_prefixes=[]'`(규칙을 만들지 않음)를 지정하세요. 443 은 Lab 07 의 TLS 리스너를 추가할 때 NSG 를 다시 고치지 않도록 미리 허용했습니다.
>
> `snet-aks-apiserver` 에는 NSG 를 연결하지 않았습니다(위임 서브넷, VNet 안의 트래픽은 기본 허용). NSG 를 붙인다면 노드 서브넷 → API 서버 서브넷 TCP 443 · 4443, `AzureLoadBalancer` → API 서버 서브넷 TCP 9988 인바운드를 먼저 허용해야 합니다([API Server VNet Integration](https://learn.microsoft.com/azure/aks/api-server-vnet-integration#network-security-group-nsg-security-rules)).

## 코드

<!-- tf:include path="terraform/03-network/versions.tf" -->
```hcl title="terraform/03-network/versions.tf"
terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  # storage_account_name / container_name are injected with `terraform init -backend-config=../backend.hcl`.
  backend "azurerm" {
    use_azuread_auth = true
    key              = "03-network.tfstate"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/03-network/providers.tf" -->
```hcl title="terraform/03-network/providers.tf"
provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/03-network/variables.tf" -->
```hcl title="terraform/03-network/variables.tf"
variable "workload" {
  description = "Workload name (3–8 lowercase letters or digits)"
  type        = string
  default     = "aksdemo"
}

variable "environment" {
  description = "Environment (dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "koreacentral"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "address_space" {
  description = "VNet address space. Choose a range that does not overlap with on-premises or peered networks."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidrs" {
  description = <<-EOT
    Subnet CIDRs.
    - aks_nodes: node IPs only (Azure CNI Overlay is used, so Pod IPs are not taken from this subnet)
    - aks_apiserver: for API Server VNet Integration. At least /28, dedicated to AKS
    - ingress: internal load balancer frontend IP (Gateway)
    - private_endpoints: Private Endpoints for ACR / Key Vault, etc.
  EOT
  type = object({
    aks_nodes         = string
    aks_apiserver     = string
    ingress           = string
    private_endpoints = string
  })
  default = {
    aks_nodes         = "10.10.0.0/24"
    aks_apiserver     = "10.10.1.0/28"
    ingress           = "10.10.2.0/27"
    private_endpoints = "10.10.3.0/27"
  }

  validation {
    condition     = alltrue([for cidr in values(var.subnet_cidrs) : can(cidrhost(cidr, 0))])
    error_message = "All values in subnet_cidrs must be valid CIDRs and must fall within address_space."
  }
}

variable "pod_cidr" {
  description = <<-EOT
    Pod CIDR for Azure CNI Overlay. Use the same value as pod_cidr in 05-aks.
    Creates inbound rules on the node NSG for this range. Traffic works without them while only the default rules exist,
    but they are defensive: they keep cross-node Pod traffic (including DNS) working if a Deny rule is added later.
  EOT
  type        = string
  default     = "10.244.0.0/16"

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a valid CIDR. Example: 10.244.0.0/16"
  }
}

variable "nat_gateway_sku" {
  description = "NAT Gateway SKU. StandardV2 is zone-redundant and available in most regions."
  type        = string
  default     = "StandardV2"

  validation {
    condition     = contains(["Standard", "StandardV2"], var.nat_gateway_sku)
    error_message = "nat_gateway_sku must be Standard or StandardV2."
  }
}

variable "gateway_allowed_source_prefixes" {
  description = <<-EOT
    Sources allowed to reach HTTP (80) / HTTPS (443) on the public Gateway (internal_gateway = false in 07-ingress).
    Either the Internet service tag or a list of CIDRs. To allow only specific IPs, list them like ["203.0.113.10/32"].
    If you use only an internal Gateway, set this to []. No rule is created, and clients inside the VNet
    connect through the default rule (AllowVnetInBound).
  EOT
  type        = list(string)
  default     = ["Internet"]

  validation {
    condition     = alltrue([for prefix in var.gateway_allowed_source_prefixes : prefix == "Internet" || can(cidrhost(prefix, 0))])
    error_message = "Values in gateway_allowed_source_prefixes must be Internet or a valid CIDR."
  }

  # An NSG rule cannot take a service tag in the list (plural) attribute.
  validation {
    condition     = !contains(var.gateway_allowed_source_prefixes, "Internet") || length(var.gateway_allowed_source_prefixes) == 1
    error_message = "The Internet service tag cannot be combined with other values. Use [\"Internet\"] alone or a list of CIDRs."
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/03-network/main.tf" -->
```hcl title="terraform/03-network/main.tf"
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

  # StandardV2 NAT Gateway / Public IP are zone-redundant by default, so zones is not specified.
  nat_zones = var.nat_gateway_sku == "StandardV2" ? null : ["1"]

  # Private DNS Zones for Private Endpoints. To support a new PaaS service, just add one line here.
  private_dns_zones = {
    acr       = "privatelink.azurecr.io"
    key_vault = "privatelink.vaultcore.azure.net"
  }

  # Removes duplicates so that a source listed twice appears only once in the NSG rule.
  gateway_sources = distinct(var.gateway_allowed_source_prefixes)
}

# ---------------------------------------------------------------------------
# Resource group + VNet
# An AWS VPC is regional and its subnets are tied to an AZ, whereas
# an Azure VNet subnet spans the whole region and AZs are specified per VM/node.
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
# default_outbound_access_enabled = false : does not rely on the "default outbound IP";
# makes these private subnets that reach the internet only through the NAT Gateway.
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

  # API Server VNet Integration: the API server of the AKS control plane is projected into this subnet.
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

  # Apply NSG rules to Private Endpoints as well (the default is Disabled).
  private_endpoint_network_policies = "Enabled"
}

# ---------------------------------------------------------------------------
# NSG (plays the role of both an AWS Security Group and a NACL)
# - Stateful, attached to a subnet/NIC, lower priority numbers are evaluated first, supports both Allow and Deny
# - AKS does not modify "the NSG you attached to the subnet", and it does not add rules for Services (LoadBalancer)
#   either, so the inbound allow rules the node subnet needs are defined explicitly below with Terraform.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "aks_nodes" {
  name                = module.naming.names.nsg_aks_nodes
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

# snet-ingress has only the internal LB frontend IP and no VMs (NICs). Traffic to the internal Gateway is
# evaluated by the NSG of the node subnet (the backend), so this NSG has no rules.
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

# The Private Endpoint subnet allows only "HTTPS from the AKS node subnet" and blocks all other traffic inside the VNet.
# (The default rule AllowVnetInBound has priority 65000, so a Deny rule at 4000 blocks it first.)
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
# Inbound allow rules for the node subnet NSG (priority: 100s = intra-cluster traffic, 200s = Gateway)
#
# What passes with the default rules alone (observed: traffic is still not blocked after the rules are deleted)
#   - node ↔ node, API server subnet → node (kubelet 10250), VNet client → internal Gateway : AllowVnetInBound (65000)
#   - Azure Load Balancer health probe                                                      : AllowAzureLoadBalancerInBound (65001)
#   - Azure CNI Overlay node → Pod, Pod ↔ Pod (including DNS)                               : passes via the default rules
#
# What you must allow yourself (required)
#   - Public Gateway: a Standard LB blocks inbound by default, so the NSG must allow it (AllowGatewayHttpHttps).
#
# What is allowed in advance (defensive)
#   - Overlay Pod traffic is not encapsulated, so the subnet NSG applies to it as is. The default rules allow it today,
#     but if an organizational policy or hardening later adds a Deny rule (e.g., DenyAllInBound at 4000), Pod-to-Pod
#     traffic between nodes and DNS break (observed: a Deny rule causes timeouts; with the allow rules below, traffic
#     passes). The allow rules the AKS docs require (node → Pod, Pod → Pod) are created up front.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_rule" "nodes_allow_nodes_to_pods" {
  name                        = "AllowNodesToPods"
  description                 = "Service traffic routing: node -> Pod (Azure CNI Overlay)"
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
  description                 = "Pod-to-Pod and Pod -> Service traffic (including DNS) (Azure CNI Overlay)"
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

# API Server VNet Integration: traffic from the API server (delegated subnet) to the nodes
# (kubectl exec · logs · port-forward go to kubelet 10250).
# The default rule (AllowVnetInBound) lets it through as well, but it breaks once a Deny rule is added later
# (observed: with a Deny rule added, exec fails with connection reset; with this rule, it passes).
# The Pod CIDR destination is not confirmed to be needed on the webhook call path, so it is included only defensively.
resource "azurerm_network_security_rule" "nodes_allow_apiserver" {
  name                         = "AllowApiServerToCluster"
  description                  = "API server -> node (kubelet 10250: exec, logs), Pod. Keeps kubectl exec working even if a Deny rule is added"
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

# Public Gateway (Standard LB): allowed sources → HTTP/HTTPS listeners.
# The public LB's public IP is created later by AKS and is unknown at plan time, and the nodes have no public IP,
# so only the service the LB exposes on 80/443 (the Gateway) is reachable from the internet. That is why the
# destination is *. (443 is allowed in advance so the NSG doesn't need to be edited again when you add the TLS
# listener in Lab 07.)
# A single source value goes in the singular attribute and multiple values in the plural one
# (only one of the two can be set; service tags can only be used in the singular).
# If gateway_allowed_source_prefixes = [], no rule is created (internal Gateway only).
resource "azurerm_network_security_rule" "nodes_allow_gateway" {
  count = length(local.gateway_sources) > 0 ? 1 : 0

  name                        = "AllowGatewayHttpHttps"
  description                 = "Inbound HTTP/HTTPS for the public Gateway (Standard LB)"
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
# NAT Gateway : sends the nodes' outbound (internet) traffic out through a static public IP.
# Same structure as an AWS "private subnet + NAT Gateway", but in Azure you attach it directly to the subnet.
# (No route table changes are needed.)
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
# Private DNS Zone : resolves the FQDN of a Private Endpoint to a private IP.
# With an AWS Interface VPC Endpoint, enabling "Private DNS" once is enough, but in Azure you configure it yourself:
# create the Zone → link it to the VNet → attach a DNS Zone Group (on the Private Endpoint side).
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
```
<!-- /tf:include -->

<!-- tf:include path="terraform/03-network/outputs.tf" -->
```hcl title="terraform/03-network/outputs.tf"
output "resource_group_name" {
  description = "Network resource group"
  value       = azurerm_resource_group.network.name
}

output "vnet_name" {
  description = "VNet name (looked up with a data source in later stacks)"
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Map of subnet IDs"
  value = {
    aks_nodes         = azurerm_subnet.aks_nodes.id
    aks_apiserver     = azurerm_subnet.aks_apiserver.id
    ingress           = azurerm_subnet.ingress.id
    private_endpoints = azurerm_subnet.private_endpoints.id
  }
}

output "nat_gateway_public_ip" {
  description = "Static public IP for cluster outbound traffic (the value to add to external services' firewall allow lists)"
  value       = azurerm_public_ip.nat.ip_address
}

output "private_dns_zone_names" {
  description = "Private DNS Zones for Private Endpoints"
  value       = [for zone in azurerm_private_dns_zone.this : zone.name]
}
```
<!-- /tf:include -->

**단위 테스트** (Azure 없이 `terraform test` 로 plan 로직 검증)

<!-- tf:include path="terraform/03-network/tests/plan.tftest.hcl" -->
```hcl title="terraform/03-network/tests/plan.tftest.hcl"
# Verify only the plan logic, without Azure: terraform -chdir=terraform/03-network test
mock_provider "azurerm" {
  source = "../mocks"
}

run "plan_defaults" {
  command = plan

  assert {
    condition     = length(azurerm_subnet.aks_apiserver.delegation) == 1
    error_message = "The API server subnet must be delegated to Microsoft.ContainerService/managedClusters."
  }

  assert {
    condition     = azurerm_subnet.aks_nodes.default_outbound_access_enabled == false
    error_message = "The node subnet must not rely on the default outbound IP (use a NAT Gateway)."
  }
}

run "plan_standard_nat" {
  command = plan

  variables {
    nat_gateway_sku = "Standard"
  }

  assert {
    condition     = azurerm_nat_gateway.this.zones == toset(["1"])
    error_message = "A Standard NAT Gateway must be placed in a single availability zone."
  }
}

# Node NSG: AKS does not modify an NSG attached to the subnet, so the required inbound allow rules must exist in Terraform.
run "nodes_nsg_allows_overlay_and_gateway_traffic" {
  command = plan

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_nodes_to_pods.source_address_prefix == var.subnet_cidrs.aks_nodes &&
      azurerm_network_security_rule.nodes_allow_nodes_to_pods.destination_address_prefix == var.pod_cidr
    )
    error_message = "Inbound from the node subnet → Pod CIDR must be allowed (Service traffic routing in Azure CNI Overlay)."
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_pods_to_pods.source_address_prefix == var.pod_cidr &&
      azurerm_network_security_rule.nodes_allow_pods_to_pods.destination_address_prefix == var.pod_cidr
    )
    error_message = "Inbound between Pod CIDRs must be allowed (so cross-node Pod traffic survives a Deny rule added later)."
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_apiserver.source_address_prefix == var.subnet_cidrs.aks_apiserver &&
      azurerm_network_security_rule.nodes_allow_apiserver.destination_address_prefixes == toset([var.subnet_cidrs.aks_nodes, var.pod_cidr])
    )
    error_message = "Inbound from the API server subnet → node/Pod CIDR must be allowed."
  }

  assert {
    condition = (
      length(azurerm_network_security_rule.nodes_allow_gateway) == 1 &&
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefix == "Internet" &&
      azurerm_network_security_rule.nodes_allow_gateway[0].destination_port_ranges == toset(["80", "443"])
    )
    error_message = "With the default (public Gateway), inbound internet → 80/443 must be allowed."
  }
}

run "gateway_rule_with_multiple_cidrs" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = ["203.0.113.0/24", "198.51.100.10/32"]
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefixes == toset(["203.0.113.0/24", "198.51.100.10/32"]) &&
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefix == null
    )
    error_message = "With multiple sources, only the plural attribute (source_address_prefixes) must be used."
  }
}

run "gateway_rule_with_single_cidr" {
  command = plan

  variables {
    # Duplicates are merged into one, so the singular attribute is used, just as with a single value.
    gateway_allowed_source_prefixes = ["203.0.113.10/32", "203.0.113.10/32"]
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefix == "203.0.113.10/32" &&
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefixes == null
    )
    error_message = "With only one source, only the singular attribute (source_address_prefix) must be used."
  }
}

run "no_gateway_rule_for_internal_only" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = []
  }

  assert {
    condition     = length(azurerm_network_security_rule.nodes_allow_gateway) == 0
    error_message = "If gateway_allowed_source_prefixes = [], the public Gateway allow rule must not be created."
  }
}

run "rejects_internet_tag_mixed_with_cidr" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = ["Internet", "203.0.113.0/24"]
  }

  expect_failures = [var.gateway_allowed_source_prefixes]
}

run "rejects_invalid_gateway_source" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = ["not-a-cidr"]
  }

  expect_failures = [var.gateway_allowed_source_prefixes]
}

run "rejects_invalid_cidr" {
  command = plan

  variables {
    subnet_cidrs = {
      aks_nodes         = "not-a-cidr"
      aks_apiserver     = "10.10.1.0/28"
      ingress           = "10.10.2.0/27"
      private_endpoints = "10.10.3.0/27"
    }
  }

  expect_failures = [var.subnet_cidrs]
}
```
<!-- /tf:include -->

> [!NOTE]
> 이 테스트가 참조하는 mock 값은 [부록](99-appendix.md)의 `terraform/mocks/azurerm.tfmock.hcl` 에 있습니다.

## 실습 따라하기

```bash
cd terraform/03-network
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan        # 약 26개 리소스
terraform apply tfplan            # 2~4분
```

### 검증

```bash
RG=$(terraform output -raw resource_group_name)
VNET=$(terraform output -raw vnet_name)

az network vnet subnet list -g "$RG" --vnet-name "$VNET" \
  --query "[].{name:name, cidr:addressPrefix, delegation:delegations[0].serviceName, natGw:natGateway.id!=null}" -o table

terraform output nat_gateway_public_ip         # 클러스터의 아웃바운드 고정 IP
az network nat gateway show -g "$RG" -n "$(az network nat gateway list -g "$RG" --query '[0].name' -o tsv)" \
  --query "{sku:sku.name, zones:zones, idleTimeout:idleTimeoutInMinutes}" -o json

# 노드 NSG 의 인바운드 허용 규칙
NSG=$(az network nsg list -g "$RG" --query "[?ends_with(name, '-aks-nodes')].name | [0]" -o tsv)
az network nsg rule list -g "$RG" --nsg-name "$NSG" -o table
```

기대 결과: `snet-aks-nodes` 에 `natGw: true`, `snet-aks-apiserver` 에 delegation `Microsoft.ContainerService/managedClusters`. 노드 NSG 에는 `AllowNodesToPods`(100) · `AllowPodsToPods`(110) · `AllowApiServerToCluster`(120) · `AllowGatewayHttpHttps`(200) 가 보입니다.

### 자동 검증 스크립트

서브넷 위임, NAT Gateway 연결과 고정 공인 IP, NSG, Private DNS Zone 의 VNet 연결까지 한 번에 확인합니다 (읽기 전용).

```bash
cd ../..                          # 저장소 루트에서 실행
scripts/verify.sh 03-network
```

<!-- tf:include path="scripts/verify/03-network.sh" -->
```bash title="scripts/verify/03-network.sh"
#!/usr/bin/env bash
# Lab 03 verification: checks that the VNet · subnets · NSGs · NAT Gateway · Private DNS were created as designed (read-only).
#   AWS comparison: VPC + subnets + Security Group/NACL + NAT Gateway + Route 53 private hosted zone
# Usage: scripts/verify.sh 03-network
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg vnet_name nat_ip vnet sn nat natsku pips zones zone links rules r
  rg="$(tf_out 03-network resource_group_name)"
  vnet_name="$(tf_out 03-network vnet_name)"
  nat_ip="$(tf_out 03-network nat_gateway_public_ip)"

  section "03-network · VNet (${vnet_name:-?})"
  if [ -z "$rg" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 03-network?"
    return
  fi

  vnet="$(azj network vnet show -g "$rg" -n "$vnet_name")"
  if [ -z "$vnet" ]; then
    fail "VNet not found: $vnet_name"
    return
  fi
  expect_set "Address space" "$(jv "$vnet" '.addressSpace.addressPrefixes | join(",")')"

  # Azure subnets aren't tied to an AZ; they span the whole region (in AWS, each subnet is pinned to an AZ).
  for sn in snet-aks-nodes snet-aks-apiserver snet-ingress snet-private-endpoints; do
    jq_ok "Subnet $sn exists" "$vnet" "[.subnets[] | select(.name == \"$sn\")] | length == 1"
  done
  jq_ok "API server subnet is delegated to managedClusters (API Server VNet Integration)" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-apiserver") | .delegations | any(.serviceName == "Microsoft.ContainerService/managedClusters")'
  jq_ok "NAT Gateway attached to the node subnet (static egress)" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-nodes") | .natGateway.id != null'
  jq_ok "Default outbound access disabled on the node subnet" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-nodes") | .defaultOutboundAccess == false'
  for sn in snet-aks-nodes snet-ingress snet-private-endpoints; do
    jq_ok "NSG attached: $sn" "$vnet" ".subnets[] | select(.name == \"$sn\") | .networkSecurityGroup.id != null"
  done

  # AKS doesn't modify an NSG attached to the subnet, so the node NSG's inbound allow rules
  # must be the ones Terraform created.
  rules="$(nodes_nsg_rules "$rg")"
  if [ -z "$rules" ]; then
    fail "Can't read the rules of the node subnet NSG (…-aks-nodes)"
  else
    for r in AllowNodesToPods AllowPodsToPods AllowApiServerToCluster; do
      jq_ok "Node NSG inbound allow: $r (Azure CNI Overlay / API Server VNet Integration)" "$rules" \
        "any(.[]; .name == \"$r\" and .direction == \"Inbound\" and .access == \"Allow\")"
    done
    # If gateway_allowed_source_prefixes = [] (internal Gateway only), it's normal for this rule to be absent.
    jq_warn "Node NSG inbound allow: AllowGatewayHttpHttps (public Gateway 80/443. Fine if you only use an internal Gateway)" "$rules" \
      'any(.[]; .name == "AllowGatewayHttpHttps" and .direction == "Inbound" and .access == "Allow")'
  fi

  nat="$(azj network nat gateway list -g "$rg")"
  natsku="$(jv "$nat" '.[0].sku.name')" # nat_gateway_sku variable: StandardV2 (default) / Standard
  case "$natsku" in
    StandardV2) pass "NAT Gateway SKU = StandardV2 (zone-redundant)" ;;
    Standard) warn "NAT Gateway SKU = Standard (not zone-redundant. Use it only in regions that don't support StandardV2)" ;;
    *) fail "NAT Gateway SKU: expected StandardV2 or Standard / actual '${natsku:-(none)}'" ;;
  esac
  pips="$(azj network public-ip list -g "$rg")"
  expect_eq "NAT public IP = terraform output" "$(jv "$pips" '[.[] | select(.name | startswith("pip-ng-"))][0].ipAddress')" "$nat_ip"

  # The Private DNS Zones for Private Endpoints must be linked to this VNet so that the names resolve to private IPs.
  zones="$(az network private-dns zone list -g "$rg" --query '[].name' -o tsv 2>/dev/null)"
  for zone in privatelink.azurecr.io privatelink.vaultcore.azure.net; do
    if printf '%s\n' "$zones" | grep -qx "$zone"; then
      links="$(azj network private-dns link vnet list -g "$rg" -z "$zone")"
      jq_ok "Private DNS Zone $zone linked to the VNet" "$links" "any(.[]; .virtualNetwork.id | endswith(\"/$vnet_name\"))"
    else
      fail "Private DNS Zone not found: $zone"
    fi
  done
}

# You can also run it directly (scripts/verify/03-network.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `SubnetsHaveNoAddressPrefixes` / CIDR 충돌 | 온프레미스·피어링 VNet 과 겹치지 않는 `address_space` 를 지정하세요. |
| `StandardV2 NAT gateway is not supported in region` | `-var nat_gateway_sku=Standard` (이 경우 `zones = ["1"]` 단일 영역). |
| PE 서브넷에서 연결이 안 됨 | NSG 규칙 우선순위(100 허용 → 4000 거부)와 출발지(노드 서브넷 CIDR)를 확인. |
| 노드 간 Pod 통신 · DNS 가 안 됨 (Lab 05 이후) | 노드 NSG 에 Deny 규칙이 추가되지 않았는지, `AllowPodsToPods` 가 05-aks 의 `pod_cidr` 와 같은 대역인지 확인하세요. 다르면 두 스택의 `pod_cidr` 를 맞추고 03-network 를 다시 apply. |
| `kubectl exec` · `logs` 가 `connection reset` / 타임아웃 | 노드 NSG 에 Deny 규칙이 있다면 `AllowApiServerToCluster`(API 서버 서브넷 → 노드 10250)가 남아 있는지 확인. |
| 공용 Gateway 가 타임아웃 (Lab 07) | 노드 NSG 에 `AllowGatewayHttpHttps` 가 있는지, `gateway_allowed_source_prefixes` 에 내 IP 가 포함되는지 확인 (`az network nsg rule list`). 내부 Gateway 는 VNet 밖에서 접근할 수 없습니다. |

다음 → [Lab 04. 플랫폼 서비스: ACR · Key Vault · 모니터링 · AKS 용 ID](04-platform.md)
