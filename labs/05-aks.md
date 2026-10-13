# Lab 05. AKS 클러스터 (Standard): EKS 와 무엇이 다른가

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 40분 (apply 15–25분) | **시간당 약 $1.7–2** (Standard 티어 + 노드 6대 이상) | `terraform/05-aks` | [04. 플랫폼 서비스](04-platform.md) |

## 이번 실습에서 만드는 것

![AKS 클러스터 구성 (Standard)](diagrams/aks-cluster.svg)

## EKS 경험자를 위한 비교

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| `aws_eks_cluster` | `azurerm_kubernetes_cluster` | 컨트롤 플레인은 둘 다 관리형. **업타임 SLA 는 `sku_tier = "Standard"`** 부터(Free 는 SLA 없음). |
| `aws_eks_node_group` / ASG | `default_node_pool` + `azurerm_kubernetes_cluster_node_pool` | **System 풀**(필수, 시스템 파드 전용)과 **User 풀**을 분리합니다. 노드 = VMSS. |
| 노드는 내 VPC 의 EC2 | **노드 리소스 그룹**(`node_resource_group`) | 클러스터 RG 와 별개의 RG 에 VMSS/LB/디스크가 생깁니다. 직접 수정 금지. |
| VPC CNI (파드 = VPC IP) | `network_plugin = azure` + `network_plugin_mode = overlay` | 파드는 `pod_cidr` 사용 → VNet IP 절약. 클러스터 밖에서 파드 IP 로 직접 접근은 불가(필요하면 Pod Subnet 모드). |
| (Calico/Cilium 추가 설치) | `network_data_plane = cilium`, `network_policy = cilium` | 관리형 Cilium. kube-proxy 대체 + NetworkPolicy 강제 + (옵션) ACNS 관측/보안. |
| 퍼블릭/프라이빗 엔드포인트 + CIDR 제한 | `api_server_access_profile` (VNet Integration + `authorized_ip_ranges`) / `private_cluster_enabled` | VNet Integration 은 API 서버를 내 서브넷의 ILB 로 투영합니다(프라이빗 엔드포인트/DNS 존 불필요). |
| aws-auth ConfigMap / access entries | `azure_active_directory_role_based_access_control` + 역할 할당 | **Azure RBAC for Kubernetes**: "Azure Kubernetes Service RBAC Cluster Admin" 같은 역할로 쿠버네티스 권한까지 제어. |
| (로컬 admin 없음) | `local_account_disabled = true` | AKS 는 기본적으로 정적 인증서 kubeconfig(로컬 계정)가 있습니다 → **반드시 끄세요**. |
| IRSA / Pod Identity | `oidc_issuer_enabled` + `workload_identity_enabled` | Lab 06. azurerm 5.x 는 OIDC issuer 기본값이 `true`. |
| EKS 업그레이드 | `kubernetes_version`(생성 시점) + `automatic_upgrade_channel` + `maintenance_window_*` | patch 는 AKS 가 유지보수 창에 자동 적용, minor 는 사전 점검 후 `az aks upgrade` 로 단계적으로(Lab 09). 생성 이후 버전은 AKS 가 관리하므로 Terraform 은 버전 변경을 무시합니다(`ignore_changes`). |
| Karpenter / Cluster Autoscaler | `auto_scaler_profile` (CA) / `node_provisioning_profile` (NAP) | 이 실습은 Cluster Autoscaler(`mode = "Manual"`). NAP 는 Lab 10(Automatic)에서 체험. |

## 설계 결정 (Best practice)

| 설정 | 값 | 이유 (WAF / 베이스라인 아키텍처 권장) |
|---|---|---|
| `sku_tier` | `Standard` | 업타임 SLA, 비용 분석 애드온. 운영 필수. |
| `kubernetes_version` | `"1.36"` (2026-10 GA 최신) | **생성 시점의 minor alias** 입니다. 이후 patch/minor 는 AKS 가 관리하므로 `lifecycle { ignore_changes }` 로 Terraform 이 되돌리지 않게 했습니다(alias 와 실제 patch 버전이 달라 생기는 영구 diff 방지). AKS 기본값은 1.35 이며, 보수적인 운영이라면 N-1(1.35)도 좋은 선택입니다. 1.37 은 GA 예정(현재 preview). `check` 블록이 리전 지원 여부를 경고. |
| `automatic_upgrade_channel` / `node_os_upgrade_channel` | `patch` / `NodeImage` | 보안 패치는 유지보수 창에 자동, **minor 업그레이드는 사전 점검(Lab 09)을 거쳐 직접**. 시간은 `maintenance_window_*` 로 통제. |
| System 풀 | D4ds_v5 ×3(영역별 1대), `only_critical_addons_enabled` | 시스템 파드와 앱 분리, 영역 장애 내성. 4 vCPU 이상 권장. |
| User 풀 | D4ds_v5 ×3–6 (autoscaler) | 앱 전용. 최소 3대(3개 영역에 걸친 풀이라 영역별 1대씩 배치되는 것이 일반적)로 영역 장애에도 가용성 유지. 오토스케일 확장 시 영역 균형은 best-effort 입니다. 엄격한 균형이 필요하면 영역별로 풀을 따로 만들고 `balance_similar_node_groups` 를 쓰세요. |
| OS | `AzureLinux3` + Ephemeral OS 디스크(64GB) | 경량/강화 OS, 빠른 노드 교체, 디스크 비용 없음. (Azure Linux 2.0 은 2026-10-31 이미지 제거) |
| 네트워크 | CNI Overlay + Cilium, `userAssignedNATGateway` | IP 절약, eBPF 데이터 플레인, 고정 egress IP. kubenet 은 신규에 비권장. |
| API 서버 | VNet Integration + authorized IP ranges | 공용이지만 내 IP 만. `enable_private_cluster = true` 로 완전 프라이빗 전환 가능(아래 심화). |
| 인증 | Entra + Azure RBAC, `local_account_disabled = true` | 감사 가능한 ID 로만 접근. 정적 kubeconfig 제거. |
| 애드온 | Azure Policy, Key Vault CSI, Image Cleaner, KEDA, VPA, Cost analysis | 거버넌스/시크릿/비용 가시성. |
| 관측성 | Managed Prometheus + Container Insights(DCR) + 컨트롤 플레인 진단 로그 | `kube-audit-admin`(저렴) 위주 수집. Prometheus recording rule 로 기본 Grafana 대시보드 지원. |
| 포함하지 않은 것 | Azure Firewall egress, App Gateway+WAF, 멀티 리전 | 비용/복잡도. 부록의 "프로덕션 체크리스트" 참고. |

> [!IMPORTANT]
> **azurerm 4.x–5.x 에서 바뀐 점**: `node_provisioning_profile { mode = "Manual" }` 블록이 5.x 에서 **필수**입니다(없으면 `validate` 오류). `oidc_issuer_enabled` 기본값은 5.x 에서 `true`, `default_node_pool` 의 `enable_auto_scaling` 은 `auto_scaling_enabled` 로 바뀌었고, `os_disk_type`/`only_critical_addons_enabled`/`vm_size` 등을 바꿀 때는 `temporary_name_for_rotation` 이 필요합니다.

> [!NOTE]
> **AzAPI 를 쓰는 이유**: azurerm 5.9 는 *컨트롤 플레인 메트릭*과 *Gateway API*(Managed Gateway API CRD + 애플리케이션 라우팅 Istio 구현) 설정을 아직 노출하지 않습니다. 같은 클러스터를 AzAPI 의 `azapi_update_resource` 로 **부분 업데이트**합니다. 두 업데이트가 같은 클러스터에 동시에 PUT 하지 않도록 `depends_on` 으로 직렬화했습니다.

## 코드

<!-- tf:include path="terraform/05-aks/versions.tf" -->
```hcl title="terraform/05-aks/versions.tf"
terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }

    # azurerm 이 아직 지원하지 않는 AKS 신기능(Gateway API, 컨트롤 플레인 메트릭)은 AzAPI 로 켭니다.
    # (AWS 에서 aws 프로바이더가 따라오지 못하는 신규 API 를 awscc 프로바이더로 쓰는 것과 비슷합니다.)
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "05-aks.tfstate"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/05-aks/providers.tf" -->
```hcl title="terraform/05-aks/providers.tf"
provider "azurerm" {
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# AzAPI 도 ARM_SUBSCRIPTION_ID 와 Azure CLI 로그인 정보를 그대로 사용합니다.
provider "azapi" {}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/05-aks/variables.tf" -->
```hcl title="terraform/05-aks/variables.tf"
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

variable "allowed_ip_ranges" {
  description = <<-EOT
    Kubernetes API 서버에 접근을 허용할 관리자 공인 IP (CIDR 목록).
    예: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
    enable_private_cluster = true 이면 사용하지 않습니다.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "allowed_ip_ranges 에 CIDR 을 1개 이상 지정하세요. 예: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    클러스터를 "처음 만들 때" 사용할 Kubernetes 버전 (minor alias). 2026-10 기준 GA 최신은 1.36, AKS 기본값은 1.35 입니다.
    생성 이후의 버전은 AKS 가 관리하므로(patch 는 automatic_upgrade_channel = "patch", minor 는 Lab 09 절차) Terraform 은 이 값의 변경을 무시합니다.
    확인: az aks get-versions --location koreacentral -o table
  EOT
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version 은 1.36 또는 1.36.4 형식이어야 합니다."
  }
}

variable "sku_tier" {
  description = "AKS 컨트롤 플레인 등급. Standard = 업타임 SLA(99.95%, 가용 영역 사용 시) 포함. Free 는 SLA 없음."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier 는 Free, Standard, Premium 중 하나여야 합니다."
  }
}

variable "enable_private_cluster" {
  description = <<-EOT
    true 이면 API 서버를 사설 IP 로만 노출합니다(완전 private).
    이 경우 kubectl/Terraform kubernetes provider 는 VNet 안(또는 VPN/Bastion)에서만 접근 가능합니다.
    실습 기본값은 false: API Server VNet Integration + authorized IP ranges.
  EOT
  type        = bool
  default     = false
}

variable "zones" {
  description = "노드 풀을 분산 배치할 가용 영역"
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "system_node_vm_size" {
  description = "System 노드 풀 VM 크기 (최소 4 vCPU 권장)"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "system_node_min_count" {
  description = "System 노드 풀 최소 노드 수 (가용 영역 3곳에 1대씩 = 3)"
  type        = number
  default     = 3
}

variable "system_node_max_count" {
  description = "System 노드 풀 최대 노드 수"
  type        = number
  default     = 5
}

variable "user_node_vm_size" {
  description = "User 노드 풀 VM 크기"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "user_node_min_count" {
  description = "User 노드 풀 최소 노드 수 (가용 영역 3곳에 1대씩 = 3)"
  type        = number
  default     = 3
}

variable "user_node_max_count" {
  description = "User 노드 풀 최대 노드 수"
  type        = number
  default     = 6
}

variable "enable_spot_pool" {
  description = "Spot VM 노드 풀 추가 여부 (EC2 Spot 에 해당, 배치/내결함성 워크로드용)"
  type        = bool
  default     = false
}

variable "enable_gateway_api" {
  description = "Managed Gateway API CRD + 애플리케이션 라우팅 Gateway API 구현(approuting-istio) 활성화"
  type        = bool
  default     = true
}

variable "enable_defender" {
  description = "클러스터에 Microsoft Defender for Containers 프로필 연결 (구독 단위 플랜은 08-governance 에서 켭니다)"
  type        = bool
  default     = false
}

variable "grant_current_user_admin" {
  description = <<-EOT
    true 이면 terraform 을 실행하는 "현재 로그인 주체"에게 클러스터 관리자(Azure RBAC Cluster Admin) 권한을 줍니다. 실습용 기본값입니다.
    팀/CI 환경에서는 false 로 두고 admin_principal_ids 에 Entra 그룹을 지정하세요(실행 주체가 바뀌어도 권한이 흔들리지 않습니다).
  EOT
  type        = bool
  default     = true

  validation {
    condition     = var.grant_current_user_admin || length(var.admin_principal_ids) > 0
    error_message = "grant_current_user_admin = false 이면 admin_principal_ids 에 관리자 그룹/사용자를 1개 이상 지정하세요. (로컬 계정이 비활성화되어 있어 관리자가 없으면 아무도 클러스터에 접근할 수 없습니다.)"
  }
}

variable "admin_principal_ids" {
  description = "클러스터 관리자 권한(Azure RBAC Cluster Admin)을 추가로 줄 Entra 사용자/그룹 Object ID. 팀 환경에서는 개인 대신 그룹을 권장합니다."
  type        = set(string)
  default     = []
}

variable "maintenance_utc_offset" {
  description = "유지보수 창(planned maintenance) 기준 시간대"
  type        = string
  default     = "+09:00"
}

variable "pod_cidr" {
  description = "Azure CNI Overlay Pod CIDR. VNet / 온프레미스 대역과 겹치면 안 됩니다."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "kube-dns Service IP (service_cidr 안의 주소)"
  type        = string
  default     = "10.0.0.10"
}
```
<!-- /tf:include -->

**`main.tf`** — 앞 스택의 리소스 조회, 버전 `check`, 리소스 그룹

<!-- tf:include path="terraform/05-aks/main.tf" -->
```hcl title="terraform/05-aks/main.tf"
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
# 앞선 스택(03-network, 04-platform)의 산출물을 이름 규칙으로 조회
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

# 리전에서 지원하는 GA Kubernetes 버전 목록 (az aks get-versions 와 같은 정보)
data "azurerm_kubernetes_service_versions" "current" {
  location        = var.location
  include_preview = false
}

# check 블록은 apply 를 막지 않는 "경고용 검증"입니다. 지원되지 않는 버전을 넣으면 plan 단계에서 알려줍니다.
check "kubernetes_version_is_supported" {
  assert {
    condition = anytrue([
      for v in data.azurerm_kubernetes_service_versions.current.versions :
      v == var.kubernetes_version || startswith(v, "${var.kubernetes_version}.")
    ])
    error_message = "kubernetes_version=${var.kubernetes_version} 은(는) ${var.location} 에서 GA 로 지원되지 않습니다. 지원 목록: ${join(", ", data.azurerm_kubernetes_service_versions.current.versions)}"
  }
}

# ---------------------------------------------------------------------------
# 클러스터 리소스 그룹 (노드 리소스 그룹 'rg-...-aks-nodes' 는 AKS 가 별도로 생성/관리)
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "aks" {
  name     = module.naming.names.rg_aks
  location = var.location
  tags     = local.tags
}
```
<!-- /tf:include -->

**`cluster.tf`** — 클러스터와 노드 풀 (이 실습의 핵심)

<!-- tf:include path="terraform/05-aks/cluster.tf" -->
```hcl title="terraform/05-aks/cluster.tf"
# ---------------------------------------------------------------------------
# AKS 클러스터 (Standard 모드: 플랫폼을 직접 설계/운영)
#
# EKS 와 비교
#   - 컨트롤 플레인은 Azure 가 운영 (EKS 와 동일). sku_tier = Standard 가 업타임 SLA 를 제공합니다.
#   - 노드는 VMSS(Virtual Machine Scale Set) 기반 "node pool" (≈ EKS managed node group / ASG)
#   - 노드 VM 은 별도의 "노드 리소스 그룹"(rg-...-aks-nodes)에 생성됩니다. EKS 는 내 계정에 EC2 가 그대로 보입니다.
#   - 인증은 Entra ID + Azure RBAC (≈ IAM + EKS access entries), 파드 권한은 Workload Identity (≈ IRSA/Pod Identity)
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = module.naming.names.aks
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  node_resource_group = module.naming.names.rg_aks_nodes
  dns_prefix          = module.naming.names.aks

  # --- 버전 / 업그레이드 -----------------------------------------------------
  # kubernetes_version 은 생성 시점에만 사용됩니다(아래 lifecycle.ignore_changes). 이후 patch 는 AKS 가 자동 적용합니다.
  kubernetes_version        = var.kubernetes_version
  sku_tier                  = var.sku_tier
  support_plan              = "KubernetesOfficial"
  automatic_upgrade_channel = "patch"     # 같은 minor 안에서 최신 patch 를 유지보수 창에 자동 적용 (minor 는 Lab 09 절차로 직접 올림)
  node_os_upgrade_channel   = "NodeImage" # 노드 OS 이미지는 주간 유지보수 창에서 자동 교체

  # --- 보안: Entra ID 인증 + Azure RBAC, 로컬 계정(정적 kubeconfig) 차단 ----------
  role_based_access_control_enabled = true
  local_account_disabled            = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  # --- 워크로드 ID (IRSA / EKS Pod Identity 에 해당) -----------------------------
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # --- 거버넌스 / 운영 기능 -------------------------------------------------------
  azure_policy_enabled         = true # Azure Policy for Kubernetes (OPA Gatekeeper 기반)
  image_cleaner_enabled        = true # 취약한 미사용 이미지 자동 삭제
  image_cleaner_interval_hours = 48
  cost_analysis_enabled        = var.sku_tier != "Free" # 네임스페이스/워크로드별 비용 분석 (Standard 이상)

  # --- API 서버 접근 -------------------------------------------------------------
  # API Server VNet Integration: API 서버 엔드포인트를 위임된 서브넷(내 VNet)에 투영합니다.
  # EKS 의 "Public + Private endpoint, CIDR 제한" 구성과 비슷하게 authorized IP ranges 로 공용 접근을 제한합니다.
  private_cluster_enabled             = var.enable_private_cluster
  private_cluster_public_fqdn_enabled = false

  api_server_access_profile {
    virtual_network_integration_enabled = true
    subnet_id                           = data.azurerm_subnet.aks_apiserver.id
    authorized_ip_ranges                = var.enable_private_cluster ? null : var.allowed_ip_ranges
  }

  # --- Identity: 직접 만든 UAMI 사용 (04-platform 에서 역할 할당까지 끝낸 상태) -------------
  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.cluster.id]
  }

  kubelet_identity {
    client_id                 = data.azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = data.azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = data.azurerm_user_assigned_identity.kubelet.id
  }

  # --- 네트워크: Azure CNI Overlay + Cilium, 아웃바운드는 내 NAT Gateway ----------------
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay" # Pod 는 별도 CIDR 사용 → VNet IP 를 거의 소모하지 않음 (EKS VPC CNI 와의 가장 큰 차이)
    network_data_plane  = "cilium"  # eBPF 데이터 플레인 (kube-proxy 대체)
    network_policy      = "cilium"  # NetworkPolicy 강제

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    load_balancer_sku = "standard"
    outbound_type     = "userAssignedNATGateway" # 03-network 에서 서브넷에 연결해 둔 NAT Gateway 로 egress
  }

  # --- 노드 풀: System 풀은 시스템 컴포넌트 전용 ------------------------------------
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    zones                        = var.zones
    vnet_subnet_id               = data.azurerm_subnet.aks_nodes.id
    orchestrator_version         = var.kubernetes_version
    os_sku                       = "AzureLinux3"
    os_disk_type                 = "Ephemeral" # 노드 로컬 디스크에 OS 배치: 빠르고 디스크 요금 없음
    os_disk_size_gb              = 64
    only_critical_addons_enabled = true # CriticalAddonsOnly 테인트 → 앱 파드는 User 풀로
    auto_scaling_enabled         = true
    min_count                    = var.system_node_min_count
    max_count                    = var.system_node_max_count

    # vm_size 등 일부 속성을 바꿀 때 임시 풀로 교체(rotation)하기 위한 이름
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge                     = "33%"
      drain_timeout_in_minutes      = 30
      node_soak_duration_in_minutes = 0
    }

    tags = local.tags
  }

  # Cluster Autoscaler(EKS 의 cluster-autoscaler 와 동일 계열) 사용 → 노드 풀을 직접 관리하는 "Manual" 모드.
  # Karpenter 기반 Node Auto Provisioning 을 쓰려면 mode = "Auto" (단, 노드 풀 autoscaler 는 꺼야 함).
  # AKS Automatic 은 NAP 가 기본값입니다 → Lab 10 참고.
  node_provisioning_profile {
    mode = "Manual"
  }

  auto_scaler_profile {
    balance_similar_node_groups   = true # 여러 가용 영역 풀의 노드 수를 균형 있게
    expander                      = "least-waste"
    skip_nodes_with_local_storage = true # AKS 기본값과 동일하게 명시 (블록을 쓰면 Terraform 이 false 를 보내므로)
    skip_nodes_with_system_pods   = true
  }

  # --- 유지보수 창: 업그레이드가 "언제" 일어날지 통제 (EKS 에는 없는 기능) -----------------
  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = var.maintenance_utc_offset
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Saturday"
    start_time  = "02:00"
    utc_offset  = var.maintenance_utc_offset
  }

  # --- 애드온 ---------------------------------------------------------------------
  # Secrets Store CSI Driver + Azure Key Vault Provider (≈ AWS Secrets Manager CSI provider)
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # Container Insights (로그): ama-logs 에이전트가 Log Analytics 로 전송. DCR 은 monitoring.tf 에서 정의.
  oms_agent {
    log_analytics_workspace_id      = data.azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  # Managed Prometheus (메트릭): DCR/DCE 는 monitoring.tf 에서 정의.
  monitor_metrics {}

  # KEDA(이벤트 기반 오토스케일) + VPA(요청/제한 권장)
  workload_autoscaler_profile {
    keda_enabled                    = true
    vertical_pod_autoscaler_enabled = true
  }

  dynamic "microsoft_defender" {
    for_each = var.enable_defender ? [1] : []

    content {
      log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id
    }
  }

  tags = local.tags

  lifecycle {
    # 버전은 생성 시점에만 Terraform 이 정하고, 이후에는 AKS 자동 업그레이드 채널이 관리합니다.
    # (azurerm 5.9 까지는 patch 자동 업그레이드 뒤 alias "1.36" 과 실제 버전 "1.36.6" 이 달라 매 plan 마다 diff 가 생깁니다. 5.10 에서 개선 예정)
    # minor 업그레이드 절차와 Terraform 으로 버전을 직접 관리하는 방법은 Lab 09 를 참고하세요.
    ignore_changes = [
      kubernetes_version,
      default_node_pool[0].orchestrator_version,
    ]
  }
}

# ---------------------------------------------------------------------------
# User 노드 풀: 애플리케이션 워크로드용 (EKS managed node group 에 해당)
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"

  vm_size              = var.user_node_vm_size
  zones                = var.zones
  vnet_subnet_id       = data.azurerm_subnet.aks_nodes.id
  orchestrator_version = var.kubernetes_version
  os_sku               = "AzureLinux3"
  os_disk_type         = "Ephemeral"
  os_disk_size_gb      = 64
  auto_scaling_enabled = true
  min_count            = var.user_node_min_count
  max_count            = var.user_node_max_count

  temporary_name_for_rotation = "usertmp"

  node_labels = {
    "workload-type" = "general"
  }

  upgrade_settings {
    max_surge                     = "33%"
    drain_timeout_in_minutes      = 30
    node_soak_duration_in_minutes = 0
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [orchestrator_version] # 클러스터와 동일한 이유 (자동 업그레이드가 버전을 관리)
  }
}

# ---------------------------------------------------------------------------
# (선택) Spot 노드 풀: 중단 가능한 배치/CI 워크로드용 (EC2 Spot 에 해당)
# 0 노드까지 축소되며, 파드는 toleration 이 있어야 스케줄됩니다.
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.enable_spot_pool ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"

  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = -1 # 온디맨드 가격 상한

  vm_size              = var.user_node_vm_size
  zones                = var.zones
  vnet_subnet_id       = data.azurerm_subnet.aks_nodes.id
  orchestrator_version = var.kubernetes_version
  os_sku               = "AzureLinux3"
  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 5

  node_labels = {
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule",
  ]

  tags = local.tags

  lifecycle {
    ignore_changes = [orchestrator_version]
  }
}
```
<!-- /tf:include -->

**`monitoring.tf`** — Managed Prometheus / Container Insights / 진단 설정

<!-- tf:include path="terraform/05-aks/monitoring.tf" -->
```hcl title="terraform/05-aks/monitoring.tf"
# ---------------------------------------------------------------------------
# 관측성 연결: AKS ↔ Managed Prometheus / Container Insights
#
# AWS(CloudWatch Container Insights, AMP) 에서는 "에이전트 + 워크스페이스 + IAM" 을 직접 연결하지만,
# Azure 는 Data Collection Rule(DCR) 이 "무엇을 어디로 보낼지" 를 정의하고,
# Data Collection Rule Association(DCRA) 이 DCR 을 AKS 클러스터에 연결합니다.
# ---------------------------------------------------------------------------

# --- Managed Prometheus ----------------------------------------------------------
resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  name                = module.naming.names.dce_prometheus
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  kind                = "Linux"
  tags                = local.tags
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  name                        = module.naming.names.dcr_prometheus
  location                    = azurerm_resource_group.aks.location
  resource_group_name         = azurerm_resource_group.aks.name
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id
  kind                        = "Linux"
  description                 = "Managed Prometheus: AKS 메트릭을 Azure Monitor workspace 로 전송"

  destinations {
    monitor_account {
      monitor_account_id = data.azurerm_monitor_workspace.this.id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      name    = "PrometheusDataSource"
      streams = ["Microsoft-PrometheusMetrics"]
    }
  }

  tags = local.tags
}

resource "azurerm_monitor_data_collection_rule_association" "prometheus" {
  name                    = "dcra-${module.naming.names.aks}-prometheus"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus.id
  description             = "삭제하면 이 AKS 클러스터의 Prometheus 메트릭 수집이 중단됩니다."
}

# azurerm 의 monitor_metrics 블록은 컨트롤 플레인 메트릭(apiserver, etcd 등)을 노출하지 않으므로 AzAPI 로 켭니다.
# DCRA 가 먼저 만들어진 뒤에 켜야 수집 파드가 CrashLoop 하지 않습니다.
resource "azapi_update_resource" "control_plane_metrics" {
  type        = "Microsoft.ContainerService/managedClusters@2026-05-01"
  resource_id = azurerm_kubernetes_cluster.this.id

  body = {
    properties = {
      azureMonitorProfile = {
        metrics = {
          enabled = true # monitor_metrics 블록으로 이미 켜져 있는 값. API 스키마상 필수라 함께 보냅니다.
          controlPlane = {
            enabled = true
          }
        }
      }
    }
  }

  depends_on = [azurerm_monitor_data_collection_rule_association.prometheus]
}

# --- Container Insights (로그) -----------------------------------------------------
locals {
  # 비용 최적화 구성: 성능 지표(Perf, InsightsMetrics)는 Prometheus 가 담당하므로 로그/인벤토리 스트림만 수집합니다.
  container_insights_streams = [
    "Microsoft-ContainerLogV2",
    "Microsoft-KubeEvents",
    "Microsoft-KubePodInventory",
    "Microsoft-KubeNodeInventory",
    "Microsoft-KubeServices",
    "Microsoft-KubePVInventory",
  ]
}

resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = module.naming.names.dcr_container_insights
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  kind                = "Linux"
  description         = "Container Insights: 컨테이너 로그/쿠버네티스 인벤토리를 Log Analytics 로 전송"

  destinations {
    log_analytics {
      name                  = "ciworkspace"
      workspace_resource_id = data.azurerm_log_analytics_workspace.this.id
    }
  }

  data_flow {
    streams      = local.container_insights_streams
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = local.container_insights_streams

      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Exclude"
          namespaces             = ["kube-system", "gatekeeper-system", "azure-arc"]
          enableContainerLogV2   = true
        }
      })
    }
  }

  tags = local.tags
}

# Container Insights 는 연결 이름이 반드시 "ContainerInsightsExtension" 이어야 합니다.
resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
  description             = "삭제하면 이 AKS 클러스터의 Container Insights 로그 수집이 중단됩니다."
}

# --- 컨트롤 플레인 로그 (EKS 의 control plane logging → CloudWatch Logs 에 해당) ---------------
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "diag-to-log-analytics"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated" # AKSAudit/AKSControlPlane 등 리소스 전용 테이블 사용

  dynamic "enabled_log" {
    for_each = toset([
      "kube-audit-admin", # 변경(쓰기) 작업 감사 로그만 수집: kube-audit 보다 훨씬 저렴
      "kube-apiserver",
      "kube-controller-manager",
      "kube-scheduler",
      "cluster-autoscaler",
      "guard", # Entra ID 인증/인가 로그
    ])

    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
```
<!-- /tf:include -->

**`prometheus-rules.tf`** — 기본 Grafana 대시보드가 쓰는 recording rule (그대로 복사해서 사용)

<!-- tf:include path="terraform/05-aks/prometheus-rules.tf" -->
```hcl title="terraform/05-aks/prometheus-rules.tf"
# ---------------------------------------------------------------------------
# Prometheus Recording Rules
#
# Azure Managed Grafana 의 기본 쿠버네티스 대시보드("Kubernetes / Compute Resources / ...")는
# 아래 recording rule 이 미리 계산해 둔 시계열을 사용합니다.
# 포털/CLI 로 Managed Prometheus 를 켜면 자동으로 만들어지지만, Terraform 으로 구성할 때는 직접 정의해야 합니다.
# (출처: Azure/prometheus-collector 저장소의 AddonTerraformTemplate – Linux 용 Node / Kubernetes 규칙 그룹)
# 규칙은 길기 때문에 이 파일은 "그대로 복사해서 사용" 하면 됩니다.
# ---------------------------------------------------------------------------
resource "azurerm_monitor_alert_prometheus_rule_group" "node_recording_rules" {
  name                = "NodeRecordingRulesRuleGroup-${module.naming.names.aks}"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  cluster_name        = module.naming.names.aks
  description         = "Node Recording Rules Rule Group"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [data.azurerm_monitor_workspace.this.id, azurerm_kubernetes_cluster.this.id]
  tags                = local.tags

  rule {
    enabled    = true
    record     = "instance:node_num_cpu:sum"
    expression = <<-EOT
      count without (cpu, mode) (  node_cpu_seconds_total{job="node",mode="idle"})
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_cpu_utilisation:rate5m"
    expression = <<-EOT
      1 - avg without (cpu) (  sum without (mode) (rate(node_cpu_seconds_total{job="node", mode=~"idle|iowait|steal"}[5m])))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_load1_per_cpu:ratio"
    expression = <<-EOT
      (  node_load1{job="node"}/  instance:node_num_cpu:sum{job="node"})
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_memory_utilisation:ratio"
    expression = <<-EOT
      1 - (  (    node_memory_MemAvailable_bytes{job="node"}    or    (      node_memory_Buffers_bytes{job="node"}      +      node_memory_Cached_bytes{job="node"}      +      node_memory_MemFree_bytes{job="node"}      +      node_memory_Slab_bytes{job="node"}    )  )/  node_memory_MemTotal_bytes{job="node"})
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_vmstat_pgmajfault:rate5m"
    expression = <<-EOT
      rate(node_vmstat_pgmajfault{job="node"}[5m])
    EOT
  }

  rule {
    enabled    = true
    record     = "instance_device:node_disk_io_time_seconds:rate5m"
    expression = <<-EOT
      rate(node_disk_io_time_seconds_total{job="node", device!=""}[5m])
    EOT
  }

  rule {
    enabled    = true
    record     = "instance_device:node_disk_io_time_weighted_seconds:rate5m"
    expression = <<-EOT
      rate(node_disk_io_time_weighted_seconds_total{job="node", device!=""}[5m])
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_receive_bytes_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_receive_bytes_total{job="node", device!="lo"}[5m]))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_transmit_bytes_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_transmit_bytes_total{job="node", device!="lo"}[5m]))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_receive_drop_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_receive_drop_total{job="node", device!="lo"}[5m]))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_transmit_drop_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_transmit_drop_total{job="node", device!="lo"}[5m]))
    EOT
  }
}

resource "azurerm_monitor_alert_prometheus_rule_group" "kubernetes_recording_rules" {
  name                = "KubernetesRecordingRulesRuleGroup-${module.naming.names.aks}"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  cluster_name        = module.naming.names.aks
  description         = "Kubernetes Recording Rules Rule Group"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [data.azurerm_monitor_workspace.this.id, azurerm_kubernetes_cluster.this.id]
  tags                = local.tags

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate"
    expression = <<-EOT
      sum by (cluster, namespace, pod, container) (  irate(container_cpu_usage_seconds_total{job="cadvisor", image!=""}[5m])) * on (cluster, namespace, pod) group_left(node) topk by (cluster, namespace, pod) (  1, max by(cluster, namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_working_set_bytes"
    expression = <<-EOT
      container_memory_working_set_bytes{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_rss"
    expression = <<-EOT
      container_memory_rss{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_cache"
    expression = <<-EOT
      container_memory_cache{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_swap"
    expression = <<-EOT
      container_memory_swap{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_memory:active:kube_pod_container_resource_requests"
    expression = <<-EOT
      kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_memory:kube_pod_container_resource_requests:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests"
    expression = <<-EOT
      kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_cpu:kube_pod_container_resource_requests:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_memory:active:kube_pod_container_resource_limits"
    expression = <<-EOT
      kube_pod_container_resource_limits{resource="memory",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_memory:kube_pod_container_resource_limits:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_limits{resource="memory",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_cpu:active:kube_pod_container_resource_limits"
    expression = <<-EOT
      kube_pod_container_resource_limits{resource="cpu",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) ( (kube_pod_status_phase{phase=~"Pending|Running"} == 1) )
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_cpu:kube_pod_container_resource_limits:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_limits{resource="cpu",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    label_replace(      kube_pod_owner{job="kube-state-metrics", owner_kind="ReplicaSet"},      "replicaset", "$1", "owner_name", "(.*)"    ) * on(replicaset, namespace) group_left(owner_name) topk by(replicaset, namespace) (      1, max by (replicaset, namespace, owner_name) (        kube_replicaset_owner{job="kube-state-metrics"}      )    ),    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "deployment"
    }
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="DaemonSet"},    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "daemonset"
    }
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="StatefulSet"},    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "statefulset"
    }
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="Job"},    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "job"
    }
  }

  rule {
    enabled    = true
    record     = ":node_memory_MemAvailable_bytes:sum"
    expression = <<-EOT
      sum(  node_memory_MemAvailable_bytes{job="node"} or  (    node_memory_Buffers_bytes{job="node"} +    node_memory_Cached_bytes{job="node"} +    node_memory_MemFree_bytes{job="node"} +    node_memory_Slab_bytes{job="node"}  )) by (cluster)
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:node_cpu:ratio_rate5m"
    expression = <<-EOT
      sum(rate(node_cpu_seconds_total{job="node",mode!="idle",mode!="iowait",mode!="steal"}[5m])) by (cluster) /count(sum(node_cpu_seconds_total{job="node"}) by (cluster, instance, cpu)) by (cluster)
    EOT
  }
}
```
<!-- /tf:include -->

**`gateway-api.tf`** — AzAPI 로 Gateway API 활성화

<!-- tf:include path="terraform/05-aks/gateway-api.tf" -->
```hcl title="terraform/05-aks/gateway-api.tf"
# ---------------------------------------------------------------------------
# Gateway API (Ingress 의 후속 표준) 활성화
#
# 배경: 커뮤니티 ingress-nginx 는 2026-03 에 유지보수가 종료되었고, AKS 의 "application routing add-on(NGINX)" 에 대한
#       Microsoft 보안 패치 지원도 2026-11 에 끝납니다. 후속은 Gateway API 이며, AKS 는 두 가지를 관리형으로 제공합니다.
#         1) Managed Gateway API CRDs  : Gateway/HTTPRoute 등 CRD 를 AKS 가 설치·업그레이드
#         2) approuting-istio 구현체   : 사이드카 없는 Istio 컨트롤 플레인이 Gateway 리소스를 Envoy 프록시로 만들어 줌
#
# azurerm 5.9 의 azurerm_kubernetes_cluster 는 아직 이 설정을 노출하지 않으므로 AzAPI 로 클러스터에 "부분 업데이트" 합니다.
# (Microsoft 공식 Terraform 샘플 101-aks-application-routing-gateway-api 와 같은 방식)
# ---------------------------------------------------------------------------
resource "azapi_update_resource" "gateway_api" {
  count = var.enable_gateway_api ? 1 : 0

  type        = "Microsoft.ContainerService/managedClusters@2026-05-01"
  resource_id = azurerm_kubernetes_cluster.this.id

  body = {
    properties = {
      ingressProfile = {
        gatewayAPI = {
          installation = "Standard"
        }
        webAppRouting = {
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
        }
      }
    }
  }

  # 같은 클러스터에 대한 PUT 이 겹치지 않도록 control_plane_metrics 뒤에 순서대로 실행합니다.
  depends_on = [azapi_update_resource.control_plane_metrics]
}
```
<!-- /tf:include -->

**`access.tf`** — 사람의 클러스터 접근 권한 (실습: 현재 사용자 / 팀: Entra 그룹)

> [!TIP]
> 기본값은 terraform 을 실행한 "현재 로그인 주체"를 관리자로 만듭니다(`grant_current_user_admin = true`). 팀/CI 에서는 실행 주체(사람·파이프라인)가 바뀌어도 권한이 흔들리지 않도록 `grant_current_user_admin = false` + `admin_principal_ids = ["<Entra 그룹 Object ID>"]` 로 운영하세요. 둘 다 비우면 관리자가 없는 클러스터가 되므로 `validation` 이 막습니다.

<!-- tf:include path="terraform/05-aks/access.tf" -->
```hcl title="terraform/05-aks/access.tf"
locals {
  # 현재 로그인한 주체(grant_current_user_admin) + 추가로 지정한 주체에게 클러스터 관리자 권한을 부여합니다.
  admin_principal_ids = toset(concat(
    var.grant_current_user_admin ? [data.azurerm_client_config.current.object_id] : [],
    tolist(var.admin_principal_ids),
  ))
}

# ---------------------------------------------------------------------------
# 사람의 클러스터 접근 = Azure RBAC 역할 할당
#   - Cluster User Role      : `az aks get-credentials` 로 kubeconfig 를 받을 수 있는 권한 (ARM 권한)
#   - RBAC Cluster Admin     : 쿠버네티스 API 에 대한 cluster-admin 과 동등한 권한 (데이터 플레인 권한)
# EKS 의 "IAM principal → access entry → access policy" 흐름을 Azure RBAC 하나로 처리합니다.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "cluster_user" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/05-aks/outputs.tf" -->
```hcl title="terraform/05-aks/outputs.tf"
output "resource_group_name" {
  description = "클러스터 리소스 그룹"
  value       = azurerm_resource_group.aks.name
}

output "cluster_name" {
  description = "AKS 클러스터 이름"
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "AKS 클러스터 리소스 ID"
  value       = azurerm_kubernetes_cluster.this.id
}

output "kubernetes_version" {
  description = "현재 컨트롤 플레인 버전 (patch 포함)"
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "node_resource_group" {
  description = "AKS 가 노드 VMSS/로드밸런서 등을 만든 리소스 그룹"
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  description = "Workload Identity 의 federated credential 이 신뢰할 OIDC issuer"
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "available_kubernetes_versions" {
  description = "이 리전에서 GA 로 지원되는 Kubernetes 버전"
  value       = data.azurerm_kubernetes_service_versions.current.versions
}

output "get_credentials_command" {
  description = "kubeconfig 를 받아 Entra ID 로그인(kubelogin) 형식으로 변환하는 명령"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.aks.name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/05-aks/tests/plan.tftest.hcl" -->
```hcl title="terraform/05-aks/tests/plan.tftest.hcl"
# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/05-aks test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "azapi" {}

variables {
  allowed_ip_ranges = ["203.0.113.10/32"]
}

run "plan_defaults" {
  command = plan

  assert {
    condition     = azurerm_kubernetes_cluster.this.network_profile[0].outbound_type == "userAssignedNATGateway"
    error_message = "아웃바운드는 BYO NAT Gateway 여야 합니다."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.local_account_disabled
    error_message = "로컬 계정(정적 kubeconfig)은 비활성화해야 합니다."
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.spot) == 0
    error_message = "기본값에서는 Spot 풀이 없어야 합니다."
  }

  assert {
    condition     = length(azapi_update_resource.gateway_api) == 1
    error_message = "기본값에서는 Gateway API 를 활성화해야 합니다."
  }
}

run "plan_private_cluster_with_options" {
  command = plan

  variables {
    enable_private_cluster = true
    enable_spot_pool       = true
    enable_defender        = true
    enable_gateway_api     = false
    sku_tier               = "Premium"
    admin_principal_ids    = ["11111111-1111-1111-1111-111111111111"]
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.spot) == 1
    error_message = "Spot 풀이 생성되어야 합니다."
  }

  assert {
    condition     = length(azapi_update_resource.gateway_api) == 0
    error_message = "enable_gateway_api=false 이면 azapi 업데이트가 없어야 합니다."
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 2
    error_message = "추가 관리자 1명 + 현재 사용자 = 2개의 역할 할당이어야 합니다."
  }
}

run "plan_group_admin_only" {
  command = plan

  variables {
    grant_current_user_admin = false
    admin_principal_ids      = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 1
    error_message = "현재 사용자 자동 부여를 끄면 지정한 그룹 1개만 관리자여야 합니다."
  }
}

run "rejects_cluster_without_admin" {
  command = plan

  variables {
    grant_current_user_admin = false
  }

  expect_failures = [var.grant_current_user_admin]
}

run "rejects_malformed_version" {
  command = plan

  variables {
    kubernetes_version = "v1.36"
  }

  expect_failures = [var.kubernetes_version]
}
```
<!-- /tf:include -->

## 실습 따라하기

### 1단계. 계획과 적용

```bash
cd terraform/05-aks
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan
```

plan 출력에서 확인할 점:

- `check.kubernetes_version_is_supported` 경고가 없는지 (지원 버전 목록이 출력됩니다)
- `azurerm_kubernetes_cluster.this` → `network_profile`, `api_server_access_profile`, `identity` 값이 Lab 03/04 결과와 연결되는지
- 리소스 수: 약 16개 — 클러스터, User 노드 풀, DCE·DCR·DCRA(Prometheus / Container Insights), Prometheus 규칙 그룹 2개, 진단 설정, AzAPI 업데이트 2개, 역할 할당 2개

```bash
terraform apply tfplan        # 클러스터 생성 10~20분 + azapi 업데이트 5~10분
```

> [!NOTE]
> apply 중 `azapi_update_resource` 가 한 번 더 클러스터를 업데이트하므로 전체 시간이 길어집니다. 이 시간 동안 아래 *설계 결정*을 다시 읽어 보세요.

### 2단계. kubeconfig 받기 (Entra ID 로그인)

```bash
$(terraform output -raw get_credentials_command)
# = az aks get-credentials ... && kubelogin convert-kubeconfig -l azurecli

kubectl get nodes -o wide
```

> [!TIP]
> 로컬 계정이 꺼져 있으므로 `--admin` 옵션은 동작하지 않습니다. `kubectl` 은 `az login` 세션으로 토큰을 받고, 권한은 Lab 05 의 `access.tf` 에서 부여한 *Azure Kubernetes Service RBAC Cluster Admin* 역할로 결정됩니다. 역할 전파에 1–5분 걸릴 수 있습니다(`Forbidden` 이면 잠시 후 재시도).

### 3단계. 검증

```bash
# 노드가 영역 1·2·3 에 분산되고, System/User 풀로 나뉘어 있는가
kubectl get nodes -L topology.kubernetes.io/zone,kubernetes.azure.com/mode,agentpool

# 시스템 파드 (Cilium, CoreDNS, ama-logs(컨테이너 로그), ama-metrics(Prometheus), Azure Policy 등)
kubectl get pods -A -o wide | head -40

# 클러스터 핵심 설정을 한눈에
az aks show -g "$(terraform output -raw resource_group_name)" -n "$(terraform output -raw cluster_name)" \
  --query "{version:currentKubernetesVersion, tier:sku.tier, localAccountsDisabled:disableLocalAccounts, aadRbac:aadProfile.enableAzureRbac, upgrade:autoUpgradeProfile, net:networkProfile.{plugin:networkPlugin, mode:networkPluginMode, dataplane:networkDataplane, policy:networkPolicy, outbound:outboundType}}" -o jsonc

# 권한: Azure RBAC 로 cluster-admin 과 동등한 권한이 있는가
kubectl auth can-i '*' '*'

# Gateway API: CRD 와 GatewayClass(approuting-istio) 가 준비되었는가
kubectl get crd | grep gateway.networking.k8s.io
kubectl get gatewayclass
kubectl get pods -n aks-istio-system
```

기대 결과: 노드 6대 이상(`system` 3 + `user` 3), `kubectl auth can-i` → `yes`, `GatewayClass approuting-istio` 가 `ACCEPTED True`.

### 4단계. 관측성 확인

![관측성 파이프라인: 로그 · 메트릭 · 컨트롤 플레인 로그](diagrams/observability-pipeline.svg)

데이터가 쌓이기까지 5–10분 걸립니다.

```bash
# 수집 에이전트 파드
kubectl get pods -n kube-system | grep -E "ama-logs|ama-metrics"

# Container Insights 로그 (KQL)
LAW_ID=$(az monitor log-analytics workspace show -g "$(az group list --query "[?ends_with(name,'-platform')].name | [0]" -o tsv)" \
  -n "$(az monitor log-analytics workspace list --query "[?starts_with(name,'log-')].name | [0]" -o tsv)" --query customerId -o tsv)
az monitor log-analytics query -w "$LAW_ID" --analytics-query "ContainerLogV2 | take 5 | project TimeGenerated, PodNamespace, LogMessage" -o table
az monitor log-analytics query -w "$LAW_ID" --analytics-query "AKSAuditAdmin | take 5 | project TimeGenerated, Verb, RequestUri" -o table
```

Grafana(Lab 04 의 `grafana_endpoint`)에서 **Dashboards → Azure Managed Prometheus → Kubernetes / Compute Resources / Cluster** 를 열어 노드·파드 CPU/메모리가 보이면 성공입니다.

## 심화 실험

### (a) Spot 노드 풀 추가

```bash
terraform apply -var enable_spot_pool=true
kubectl get nodes -L kubernetes.azure.com/scalesetpriority    # 파드가 스케줄되면 노드가 0 → N 으로 늘어납니다
```

### (b) 완전 프라이빗 클러스터로 전환

`terraform plan -var enable_private_cluster=true` 를 실행해 보세요. `private_cluster_enabled` 는 **변경 시 클러스터 재생성(forces replacement)** 입니다. 운영에서는 처음부터 결정해야 하며, 프라이빗이면 `kubectl`/Terraform kubernetes provider 는 VNet 내부(VPN, Bastion, 점프 호스트)에서만 접근할 수 있습니다. 임시 점검은 `az aks command invoke` 로 가능합니다.

```bash
az aks command invoke -g <rg> -n <cluster> --command "kubectl get pods -A"
```

### 자동 검증 스크립트

`az aks show` 한 번으로 클러스터 설정(보안 · 네트워크 · 업그레이드 · 애드온 · 노드 풀)을 확인하고, `kubectl` 로 노드/권한/GatewayClass/애드온 파드를 확인합니다.
임시 kubeconfig 를 쓰므로 `~/.kube/config` 는 바뀌지 않습니다.

```bash
cd ../..                          # 저장소 루트에서 실행
scripts/verify.sh 05-aks
```

<!-- tf:include path="scripts/verify/05-aks.sh" -->
```bash title="scripts/verify/05-aks.sh"
#!/usr/bin/env bash
# Lab 05 검증: AKS 클러스터가 설계한 대로 만들어졌는지 확인합니다 (읽기 전용).
#   1) az aks show 한 번으로 클러스터 설정을 읽습니다 (aws eks describe-cluster 에 해당)
#   2) kubectl 로 노드 · 권한 · 애드온을 확인합니다. kubeconfig 는 임시 파일을 써서 ~/.kube/config 를 건드리지 않습니다.
# 사용법: scripts/verify.sh 05-aks
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg name aks nodes ready want zones gc pods p bad sku channel
  rg="$(tf_out 05-aks resource_group_name)"
  name="$(tf_out 05-aks cluster_name)"

  section "05-aks · 클러스터 설정 (${name:-?})"
  if [ -z "$name" ]; then
    fail "terraform output 을 읽을 수 없습니다. 05-aks 에서 init/apply 를 마쳤나요?"
    return
  fi
  aks="$(azj aks show -g "$rg" -n "$name")"
  if [ -z "$aks" ]; then
    fail "클러스터를 찾을 수 없습니다: $name"
    return
  fi

  # --- 상태 ---
  expect_eq "프로비저닝 상태" "$(jv "$aks" .provisioningState)" "Succeeded"
  expect_eq "전원 상태" "$(jv "$aks" .powerState.code)" "Running"
  sku="$(jv "$aks" .sku.tier)" # sku_tier 변수: Free / Standard(기본) / Premium
  case "$sku" in
    Standard | Premium) pass "SKU 등급 = $sku (업타임 SLA 포함)" ;;
    Free) warn "SKU 등급 = Free (업타임 SLA 없음. 비용을 줄이려고 sku_tier 를 바꾼 것이 아니라면 Standard 로 올리세요)" ;;
    *) fail "SKU 등급: 기대 Standard 또는 Premium / 실제 '${sku:-(없음)}'" ;;
  esac
  expect_set "Kubernetes 버전" "$(jv "$aks" .currentKubernetesVersion)"

  # --- 보안 / ID ---
  expect_eq "로컬 계정(정적 kubeconfig) 비활성화" "$(jv "$aks" .disableLocalAccounts)" "true"
  expect_eq "Entra ID 통합 / Azure RBAC" "$(jv "$aks" '[.aadProfile.managed, .aadProfile.enableAzureRbac] | join("/")')" "true/true"
  expect_eq "OIDC issuer (Workload Identity 전제)" "$(jv "$aks" .oidcIssuerProfile.enabled)" "true"
  expect_eq "Workload Identity" "$(jv "$aks" .securityProfile.workloadIdentity.enabled)" "true"

  # --- 네트워크 ---
  expect_eq "CNI / 모드" "$(jv "$aks" '[.networkProfile.networkPlugin, .networkProfile.networkPluginMode] | join("/")')" "azure/overlay"
  expect_eq "데이터 플레인 / 네트워크 정책" "$(jv "$aks" '[.networkProfile.networkDataplane, .networkProfile.networkPolicy] | join("/")')" "cilium/cilium"
  expect_eq "아웃바운드 방식 (직접 만든 NAT Gateway)" "$(jv "$aks" .networkProfile.outboundType)" "userAssignedNATGateway"
  expect_eq "API 서버 VNet Integration" "$(jv "$aks" .apiServerAccessProfile.enableVnetIntegration)" "true"
  if [ "$(jv "$aks" .apiServerAccessProfile.enablePrivateCluster)" = "true" ]; then
    pass "프라이빗 클러스터 (API 서버는 VNet 안에서만 접근)"
  else
    jq_ok "API 서버 authorized IP ranges 설정" "$aks" '(.apiServerAccessProfile.authorizedIpRanges | length) >= 1'
  fi

  # --- 업그레이드 / 애드온 ---
  expect_eq "노드 OS 업그레이드 채널" "$(jv "$aks" .autoUpgradeProfile.nodeOsUpgradeChannel)" "NodeImage"
  channel="$(jv "$aks" .autoUpgradeProfile.upgradeChannel)" # 기본 patch. Lab 09 의 A / C-1 방식으로 바꿨다면 다른 값이 정상입니다.
  case "$channel" in
    patch) pass "자동 업그레이드 채널 = patch (기본 구성)" ;;
    none | stable | rapid | node-image) pass "자동 업그레이드 채널 = $channel (기본값 patch 에서 바꾼 값 - Lab 09)" ;;
    *) fail "자동 업그레이드 채널: 기대 patch (또는 none/stable/rapid/node-image) / 실제 '${channel:-(없음)}'" ;;
  esac
  jq_ok "Azure Policy 애드온" "$aks" '.addonProfiles.azurepolicy.enabled == true'
  jq_ok "Container Insights (ama-logs)" "$aks" '.addonProfiles.omsagent.enabled == true or .azureMonitorProfile.containerInsights.enabled == true'
  jq_ok "Key Vault Secrets Store CSI 드라이버" "$aks" '.addonProfiles.azureKeyvaultSecretsProvider.enabled == true'
  jq_ok "Managed Prometheus (ama-metrics)" "$aks" '.azureMonitorProfile.metrics.enabled == true'
  jq_ok "KEDA / VPA" "$aks" '.workloadAutoScalerProfile.keda.enabled == true and .workloadAutoScalerProfile.verticalPodAutoscaler.enabled == true'

  # --- 노드 풀 ---
  jq_ok "System 풀: 오토스케일 + 임시 OS 디스크" "$aks" \
    '.agentPoolProfiles[] | select(.name == "system") | .mode == "System" and .enableAutoScaling == true and .osDiskType == "Ephemeral"'
  jq_ok "User 풀: 오토스케일" "$aks" \
    '.agentPoolProfiles[] | select(.name == "user") | .mode == "User" and .enableAutoScaling == true'
  expect_ge "System 풀 가용 영역 수" "$(jv "$aks" '.agentPoolProfiles[] | select(.name == "system") | .availabilityZones | length')" 2

  # --- kubectl ---
  section "05-aks · kubectl 확인"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin 이 없어 건너뜁니다"
    return
  fi
  if ! kube_login "$rg" "$name"; then
    fail "kubeconfig 를 받지 못했습니다 (az login 과 'Azure Kubernetes Service Cluster User Role' 역할을 확인하세요)"
    return
  fi
  nodes="$(kj get nodes)"
  if [ -z "$nodes" ]; then
    if [ "$(jv "$aks" .apiServerAccessProfile.enablePrivateCluster)" = "true" ]; then
      skip "프라이빗 클러스터의 API 서버에 접속할 수 없어 kubectl 확인을 건너뜁니다 (VNet 안의 점프 호스트·VPN 에서 다시 실행하세요)"
    else
      fail "API 서버에 접속하지 못했습니다. 공인 IP 가 바뀌었다면 TF_VAR_allowed_ip_ranges 를 갱신하고 05-aks 를 apply 하세요."
    fi
    return
  fi
  ready="$(jv "$nodes" '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
  # 오토스케일 풀은 minCount 아래로 내려가지 않으므로, 풀별 최소 노드 수의 합(기본 system 3 + user 3)을 기준으로 삼습니다.
  want="$(jv "$aks" '[.agentPoolProfiles[] | if .enableAutoScaling == true then (.minCount // 0) else (.count // 0) end] | add')"
  expect_ge "Ready 노드 수 (풀별 최소 노드 수의 합)" "$ready" "${want:-1}"
  zones="$(jv "$nodes" '[.items[].metadata.labels["topology.kubernetes.io/zone"]] | unique | length')"
  expect_ge "노드가 분산된 가용 영역 수" "$zones" 2

  if [ "$(kubectl --request-timeout=20s auth can-i '*' '*' 2>/dev/null)" = "yes" ]; then
    pass "cluster-admin 권한 (Azure RBAC Cluster Admin)"
  else
    fail "cluster-admin 권한이 없습니다 (역할 전파에 최대 5분, grant_current_user_admin / admin_principal_ids 확인)"
  fi

  if [ "$(jv "$aks" '(.ingressProfile.gatewayApi // .ingressProfile.gatewayAPI // {}).installation')" = "Standard" ]; then
    gc="$(kj get gatewayclass approuting-istio)"
    jq_ok "GatewayClass approuting-istio 가 Accepted" "$gc" '.status.conditions[]? | select(.type == "Accepted") | .status == "True"'
  else
    skip "Gateway API 가 꺼져 있어 GatewayClass 확인을 건너뜁니다 (enable_gateway_api = false)"
  fi

  pods="$(kj get pods -n kube-system)"
  for p in ama-logs ama-metrics cilium coredns; do
    jq_ok "kube-system: $p 파드 Running" "$pods" "[.items[] | select((.metadata.name | startswith(\"$p\")) and .status.phase == \"Running\")] | length >= 1"
  done
  bad="$(kj get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded)"
  jq_warn "Running/Completed 가 아닌 파드가 없음" "$bad" '(.items | length) == 0'
}

# 직접 실행(scripts/verify/05-aks.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

> [!TIP]
> kubectl 단계가 "API 서버에 접속하지 못했습니다" 로 실패하면 공인 IP 가 바뀐 경우가 대부분입니다. `TF_VAR_allowed_ip_ranges` 를 갱신하고 05-aks 를 다시 `apply` 하세요.
> 기본 구성과 다르게 바꾼 설정(`sku_tier`, `enable_gateway_api`, 노드 수, Lab 09 의 업그레이드 채널)은 ✗ 대신 값을 보여 주거나 경고·건너뜀으로 표시합니다. 프라이빗 클러스터(`enable_private_cluster`)는 VNet 밖에서 kubectl 단계를 건너뜁니다.

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `QuotaExceeded` / `Operation could not be completed as it results in exceeding approved ... cores` | vCPU 쿼터 부족 → [Lab 01 의 4단계](01-prerequisites.md). 크기/개수를 줄이거나 쿼터 증설. |
| `SkuNotAvailable`, `ZonalAllocationFailed` | 해당 영역에 VM 크기 재고 없음/제한. `var.zones` 를 `["1","2"]` 로 줄이거나 `*_node_vm_size` 변경. |
| `AuthorizationFailed ... subnets/join/action` | Lab 04 의 Network Contributor 전파 지연 또는 누락. 5분 후 재시도. |
| `Unable to connect to the server: ... i/o timeout` | 공인 IP 변경 → `TF_VAR_allowed_ip_ranges` 갱신 후 `terraform apply`. |
| `error: You must be logged in to the server (Unauthorized)` | `az login` 재실행, `kubelogin convert-kubeconfig -l azurecli`. |
| `Forbidden: ... cannot list resource` | Azure RBAC 역할 전파 대기(최대 5분). 또는 `grant_current_user_admin = false` 로 적용했다면 본인(또는 소속 그룹)의 Object ID 가 `admin_principal_ids` 에 있는지 확인. |
| `terraform plan` 에서 `default_node_pool.*` 변경이 노드 풀 교체를 요구 | `temporary_name_for_rotation` 이 설정되어 있어 **순환 교체**됩니다. 교체 중 System 파드가 잠시 재스케줄됩니다. |
| Prometheus 가 비어 있음 | `ama-metrics` 파드 상태, DCRA 연결(`az monitor data-collection rule association list --resource <cluster-id>`) 확인. |

다음 → [Lab 06. Workload Identity + Key Vault CSI](06-workload-identity.md)
