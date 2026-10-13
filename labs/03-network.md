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
  ├─ snet-aks-nodes          10.10.0.0/24   AKS 노드 · NSG · NAT Gateway 연결
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
| 노드/인그레스 NSG 는 **빈 NSG** | AKS 가 `Service(type=LoadBalancer)` 생성 시 필요한 규칙을 자동으로 추가합니다. Terraform 이 이를 덮어쓰지 않도록 규칙을 정의하지 않습니다. |
| Private DNS Zone 을 네트워크 스택에서 관리 | 실제 환경에서는 연결(Connectivity) 구독에서 중앙 관리하는 경우가 많습니다. |

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

  # storage_account_name / container_name 은 `terraform init -backend-config=../backend.hcl` 로 주입합니다.
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
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다.
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
  description = "워크로드 이름 (소문자/숫자 3~8자)"
  type        = string
  default     = "aksdemo"
}

variable "environment" {
  description = "환경 구분 (dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure 리전"
  type        = string
  default     = "koreacentral"
}

variable "tags" {
  description = "모든 리소스에 추가로 붙일 태그"
  type        = map(string)
  default     = {}
}

variable "address_space" {
  description = "VNet 주소 공간. 온프레미스/피어링 대상 네트워크와 겹치지 않게 정하세요."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidrs" {
  description = <<-EOT
    서브넷 CIDR.
    - aks_nodes: 노드 IP 전용 (Azure CNI Overlay 이므로 Pod IP 는 여기서 쓰지 않습니다)
    - aks_apiserver: API Server VNet Integration 용. 최소 /28, AKS 전용
    - ingress: 내부 로드밸런서 프런트엔드 IP (Gateway)
    - private_endpoints: ACR / Key Vault 등 Private Endpoint
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
    error_message = "subnet_cidrs 의 모든 값은 올바른 CIDR 이어야 하며, address_space 안에 포함되어야 합니다."
  }
}

variable "nat_gateway_sku" {
  description = "NAT Gateway SKU. StandardV2 는 가용 영역 중복(zone-redundant)이며 대부분의 리전에서 사용 가능합니다."
  type        = string
  default     = "StandardV2"

  validation {
    condition     = contains(["Standard", "StandardV2"], var.nat_gateway_sku)
    error_message = "nat_gateway_sku 는 Standard 또는 StandardV2 여야 합니다."
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

  # StandardV2 NAT Gateway / Public IP 는 기본적으로 zone-redundant 이므로 zones 를 지정하지 않습니다.
  nat_zones = var.nat_gateway_sku == "StandardV2" ? null : ["1"]

  # Private Endpoint 용 Private DNS Zone. 새 PaaS 를 추가하면 여기에 한 줄만 추가하면 됩니다.
  private_dns_zones = {
    acr       = "privatelink.azurecr.io"
    key_vault = "privatelink.vaultcore.azure.net"
  }
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
# - 노드/인그레스 서브넷의 규칙은 AKS 가 Service(LoadBalancer) 생성 시 자동으로 추가하므로
#   Terraform 에서는 빈 NSG 만 만들어 둡니다.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "aks_nodes" {
  name                = module.naming.names.nsg_aks_nodes
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

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
```
<!-- /tf:include -->

<!-- tf:include path="terraform/03-network/outputs.tf" -->
```hcl title="terraform/03-network/outputs.tf"
output "resource_group_name" {
  description = "네트워크 리소스 그룹"
  value       = azurerm_resource_group.network.name
}

output "vnet_name" {
  description = "VNet 이름 (이후 스택에서 data source 로 조회)"
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "서브넷 ID 맵"
  value = {
    aks_nodes         = azurerm_subnet.aks_nodes.id
    aks_apiserver     = azurerm_subnet.aks_apiserver.id
    ingress           = azurerm_subnet.ingress.id
    private_endpoints = azurerm_subnet.private_endpoints.id
  }
}

output "nat_gateway_public_ip" {
  description = "클러스터 아웃바운드가 나가는 고정 공인 IP (외부 서비스 방화벽 허용 목록에 등록할 값)"
  value       = azurerm_public_ip.nat.ip_address
}

output "private_dns_zone_names" {
  description = "Private Endpoint 용 Private DNS Zone"
  value       = [for zone in azurerm_private_dns_zone.this : zone.name]
}
```
<!-- /tf:include -->

**단위 테스트** (Azure 없이 `terraform test` 로 plan 로직 검증)

<!-- tf:include path="terraform/03-network/tests/plan.tftest.hcl" -->
```hcl title="terraform/03-network/tests/plan.tftest.hcl"
# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/03-network test
mock_provider "azurerm" {
  source = "../mocks"
}

run "plan_defaults" {
  command = plan

  assert {
    condition     = length(azurerm_subnet.aks_apiserver.delegation) == 1
    error_message = "API 서버 서브넷은 Microsoft.ContainerService/managedClusters 로 위임되어야 합니다."
  }

  assert {
    condition     = azurerm_subnet.aks_nodes.default_outbound_access_enabled == false
    error_message = "노드 서브넷은 기본 아웃바운드 IP 에 의존하지 않아야 합니다 (NAT Gateway 사용)."
  }
}

run "plan_standard_nat" {
  command = plan

  variables {
    nat_gateway_sku = "Standard"
  }

  assert {
    condition     = azurerm_nat_gateway.this.zones == toset(["1"])
    error_message = "Standard NAT Gateway 는 단일 가용 영역에 배치해야 합니다."
  }
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
terraform plan -out tfplan        # 약 22개 리소스
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
```

기대 결과: `snet-aks-nodes` 에 `natGw: true`, `snet-aks-apiserver` 에 delegation `Microsoft.ContainerService/managedClusters`.

### 자동 검증 스크립트

서브넷 위임, NAT Gateway 연결과 고정 공인 IP, NSG, Private DNS Zone 의 VNet 연결까지 한 번에 확인합니다 (읽기 전용).

```bash
cd ../..                          # 저장소 루트에서 실행
scripts/verify.sh 03-network
```

<!-- tf:include path="scripts/verify/03-network.sh" -->
```bash title="scripts/verify/03-network.sh"
#!/usr/bin/env bash
# Lab 03 검증: VNet · 서브넷 · NSG · NAT Gateway · Private DNS 가 설계대로 만들어졌는지 확인합니다 (읽기 전용).
#   AWS 비교: VPC + 서브넷 + Security Group/NACL + NAT Gateway + Route 53 private hosted zone
# 사용법: scripts/verify.sh 03-network
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg vnet_name nat_ip vnet sn nat pips zones zone links
  rg="$(tf_out 03-network resource_group_name)"
  vnet_name="$(tf_out 03-network vnet_name)"
  nat_ip="$(tf_out 03-network nat_gateway_public_ip)"

  section "03-network · VNet (${vnet_name:-?})"
  if [ -z "$rg" ]; then
    fail "terraform output 을 읽을 수 없습니다. 03-network 에서 init/apply 를 마쳤나요?"
    return
  fi

  vnet="$(azj network vnet show -g "$rg" -n "$vnet_name")"
  if [ -z "$vnet" ]; then
    fail "VNet 을 찾을 수 없습니다: $vnet_name"
    return
  fi
  expect_set "주소 공간" "$(jv "$vnet" '.addressSpace.addressPrefixes | join(",")')"

  # Azure 서브넷은 AZ 에 묶이지 않고 리전 전체에 걸칩니다 (AWS 는 서브넷마다 AZ 를 지정).
  for sn in snet-aks-nodes snet-aks-apiserver snet-ingress snet-private-endpoints; do
    jq_ok "서브넷 $sn 존재" "$vnet" "[.subnets[] | select(.name == \"$sn\")] | length == 1"
  done
  jq_ok "API 서버 서브넷이 managedClusters 로 위임됨 (API Server VNet Integration)" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-apiserver") | .delegations | any(.serviceName == "Microsoft.ContainerService/managedClusters")'
  jq_ok "노드 서브넷에 NAT Gateway 연결 (고정 egress)" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-nodes") | .natGateway.id != null'
  jq_ok "노드 서브넷의 기본 아웃바운드 접근 비활성화" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-nodes") | .defaultOutboundAccess == false'
  for sn in snet-aks-nodes snet-ingress snet-private-endpoints; do
    jq_ok "NSG 연결: $sn" "$vnet" ".subnets[] | select(.name == \"$sn\") | .networkSecurityGroup.id != null"
  done

  nat="$(azj network nat gateway list -g "$rg")"
  expect_eq "NAT Gateway SKU (영역 중복)" "$(jv "$nat" '.[0].sku.name')" "StandardV2"
  pips="$(azj network public-ip list -g "$rg")"
  expect_eq "NAT 공인 IP = terraform output" "$(jv "$pips" '[.[] | select(.name | startswith("pip-ng-"))][0].ipAddress')" "$nat_ip"

  # Private Endpoint 용 Private DNS Zone 이 이 VNet 에 연결되어 있어야 이름이 사설 IP 로 풀립니다.
  zones="$(az network private-dns zone list -g "$rg" --query '[].name' -o tsv 2>/dev/null)"
  for zone in privatelink.azurecr.io privatelink.vaultcore.azure.net; do
    if printf '%s\n' "$zones" | grep -qx "$zone"; then
      links="$(azj network private-dns link vnet list -g "$rg" -z "$zone")"
      jq_ok "Private DNS Zone $zone → VNet 연결" "$links" "any(.[]; .virtualNetwork.id | endswith(\"/$vnet_name\"))"
    else
      fail "Private DNS Zone 이 없습니다: $zone"
    fi
  done
}

# 직접 실행(scripts/verify/03-network.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `SubnetsHaveNoAddressPrefixes` / CIDR 충돌 | 온프레미스·피어링 VNet 과 겹치지 않는 `address_space` 를 지정하세요. |
| `StandardV2 NAT gateway is not supported in region` | `-var nat_gateway_sku=Standard` (이 경우 `zones = ["1"]` 단일 영역). |
| PE 서브넷에서 연결이 안 됨 | NSG 규칙 우선순위(100 허용 → 4000 거부)와 출발지(노드 서브넷 CIDR)를 확인. |

다음 → [Lab 04. 플랫폼 서비스: ACR · Key Vault · 모니터링 · AKS 용 ID](04-platform.md)
