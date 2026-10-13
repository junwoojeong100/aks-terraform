<!-- lang-switch -->
[English](../05-aks.md) | **한국어**
<!-- /lang-switch -->

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

    # New AKS features that azurerm doesn't support yet (Gateway API, control plane metrics) are enabled through AzAPI.
    # (Similar to using the awscc provider on AWS for new APIs that the aws provider hasn't caught up with.)
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
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# AzAPI likewise uses ARM_SUBSCRIPTION_ID and the Azure CLI sign-in as is.
provider "azapi" {}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/05-aks/variables.tf" -->
```hcl title="terraform/05-aks/variables.tf"
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

variable "allowed_ip_ranges" {
  description = <<-EOT
    Public IPs of administrators allowed to access the Kubernetes API server (list of CIDRs).
    Example: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
    Not used when enable_private_cluster = true.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "Specify at least one CIDR in allowed_ip_ranges. Example: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes version (minor alias) used only when the cluster is first created.
    As of 2026-10, the latest GA version is 1.36 and the AKS default is 1.35.
    After creation, AKS manages the version (patches: automatic_upgrade_channel = "patch"; minors: the Lab 09 procedure),
    so Terraform ignores changes to this value.
    To check: az aks get-versions --location koreacentral -o table
  EOT
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version must be in the form 1.36 or 1.36.4."
  }
}

variable "sku_tier" {
  description = "AKS control plane tier. Standard includes the uptime SLA (99.95% with availability zones). Free has no SLA."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be one of Free, Standard, or Premium."
  }
}

variable "enable_private_cluster" {
  description = <<-EOT
    If true, the API server is exposed only on a private IP (fully private).
    In that case, kubectl and the Terraform kubernetes provider can connect only from inside the VNet (or via VPN/Bastion).
    The lab default is false: API Server VNet Integration + authorized IP ranges.
  EOT
  type        = bool
  default     = false
}

variable "zones" {
  description = "Availability zones to spread the node pools across"
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "system_node_vm_size" {
  description = "System node pool VM size (at least 4 vCPUs recommended)"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "system_node_min_count" {
  description = "Minimum node count for the System node pool (one per availability zone across 3 zones = 3)"
  type        = number
  default     = 3
}

variable "system_node_max_count" {
  description = "Maximum node count for the System node pool"
  type        = number
  default     = 5
}

variable "user_node_vm_size" {
  description = "User node pool VM size"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "user_node_min_count" {
  description = "Minimum node count for the User node pool (one per availability zone across 3 zones = 3)"
  type        = number
  default     = 3
}

variable "user_node_max_count" {
  description = "Maximum node count for the User node pool"
  type        = number
  default     = 6
}

variable "enable_spot_pool" {
  description = "Whether to add a Spot VM node pool (equivalent to EC2 Spot; for batch/fault-tolerant workloads)"
  type        = bool
  default     = false
}

variable "enable_gateway_api" {
  description = "Enable the Managed Gateway API CRDs + the application routing Gateway API implementation (approuting-istio)"
  type        = bool
  default     = true
}

variable "enable_defender" {
  description = "Attach the Microsoft Defender for Containers profile to the cluster (the subscription-level plan is enabled in 08-governance)"
  type        = bool
  default     = false
}

variable "grant_current_user_admin" {
  description = <<-EOT
    If true, grants cluster admin permissions (Azure RBAC Cluster Admin) to the "currently signed-in principal"
    that runs terraform. This is the lab default. In team/CI environments, set it to false and specify Entra groups
    in admin_principal_ids (permissions stay stable even when the executing principal changes).
  EOT
  type        = bool
  default     = true

  validation {
    condition     = var.grant_current_user_admin || length(var.admin_principal_ids) > 0
    error_message = "When grant_current_user_admin = false, specify at least one admin group/user in admin_principal_ids. (Local accounts are disabled, so with no admin, nobody can access the cluster.)"
  }
}

variable "admin_principal_ids" {
  description = "Object IDs of additional Entra users/groups to grant cluster admin permissions (Azure RBAC Cluster Admin). In team environments, prefer groups over individuals."
  type        = set(string)
  default     = []
}

variable "maintenance_utc_offset" {
  description = "UTC offset used for the maintenance windows (planned maintenance)"
  type        = string
  default     = "+09:00"
}

variable "pod_cidr" {
  description = "Azure CNI Overlay pod CIDR. Must not overlap with the VNet or on-premises ranges. Use the same value as pod_cidr in 03-network (the node NSG allow rule)."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "kube-dns Service IP (an address within service_cidr)"
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
```
<!-- /tf:include -->

**`cluster.tf`** — 클러스터와 노드 풀 (이 실습의 핵심)

<!-- tf:include path="terraform/05-aks/cluster.tf" -->
```hcl title="terraform/05-aks/cluster.tf"
# ---------------------------------------------------------------------------
# AKS cluster (Standard mode: you design and operate the platform yourself)
#
# Compared with EKS
#   - Azure operates the control plane (same as EKS). sku_tier = Standard provides the uptime SLA.
#   - Nodes are "node pools" built on VMSS (Virtual Machine Scale Sets) (≈ EKS managed node group / ASG)
#   - Node VMs are created in a separate "node resource group" (rg-...-aks-nodes).
#     With EKS, the EC2 instances appear directly in your own account.
#   - Authentication uses Entra ID + Azure RBAC (≈ IAM + EKS access entries);
#     pod permissions use Workload Identity (≈ IRSA/Pod Identity)
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = module.naming.names.aks
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  node_resource_group = module.naming.names.rg_aks_nodes
  dns_prefix          = module.naming.names.aks

  # --- Version / upgrades --------------------------------------------------------
  # kubernetes_version is used only at creation time (see lifecycle.ignore_changes below).
  # After that, AKS applies patches automatically.
  kubernetes_version        = var.kubernetes_version
  sku_tier                  = var.sku_tier
  support_plan              = "KubernetesOfficial"
  automatic_upgrade_channel = "patch"     # latest patch auto-applied in the maintenance window (minor: manual, Lab 09)
  node_os_upgrade_channel   = "NodeImage" # node OS image auto-replaced in the weekly maintenance window

  # --- Security: Entra ID auth + Azure RBAC, local accounts (static kubeconfig) disabled ---
  role_based_access_control_enabled = true
  local_account_disabled            = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  # --- Workload identity (equivalent to IRSA / EKS Pod Identity) -----------------
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # --- Governance / operations features ------------------------------------------
  azure_policy_enabled         = true # Azure Policy for Kubernetes (based on OPA Gatekeeper)
  image_cleaner_enabled        = true # automatically removes unused, vulnerable images
  image_cleaner_interval_hours = 48
  cost_analysis_enabled        = var.sku_tier != "Free" # per-namespace/workload cost analysis (Standard tier or higher)

  # --- API server access ---------------------------------------------------------
  # API Server VNet Integration: projects the API server endpoint into a delegated subnet in your own VNet.
  # Like the EKS "public + private endpoint with restricted CIDRs" setup, authorized IP ranges limit public access.
  private_cluster_enabled             = var.enable_private_cluster
  private_cluster_public_fqdn_enabled = false

  api_server_access_profile {
    virtual_network_integration_enabled = true
    subnet_id                           = data.azurerm_subnet.aks_apiserver.id
    authorized_ip_ranges                = var.enable_private_cluster ? null : var.allowed_ip_ranges
  }

  # --- Identity: use your own UAMI (roles already assigned in 04-platform) -------
  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.cluster.id]
  }

  kubelet_identity {
    client_id                 = data.azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = data.azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = data.azurerm_user_assigned_identity.kubelet.id
  }

  # --- Network: Azure CNI Overlay + Cilium, outbound through your own NAT Gateway ----
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay" # pods use a separate CIDR: almost no VNet IPs (the key difference from EKS VPC CNI)
    network_data_plane  = "cilium"  # eBPF data plane (replaces kube-proxy)
    network_policy      = "cilium"  # enforces NetworkPolicy

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    load_balancer_sku = "standard"
    outbound_type     = "userAssignedNATGateway" # egress through the NAT Gateway attached to the subnet in 03-network
  }

  # --- Node pools: the System pool is dedicated to system components -------------
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    zones                        = var.zones
    vnet_subnet_id               = data.azurerm_subnet.aks_nodes.id
    orchestrator_version         = var.kubernetes_version
    os_sku                       = "AzureLinux3"
    os_disk_type                 = "Ephemeral" # OS on the node's local disk: fast, no disk charge
    os_disk_size_gb              = 64
    only_critical_addons_enabled = true # CriticalAddonsOnly taint → app pods go to the User pool
    auto_scaling_enabled         = true
    min_count                    = var.system_node_min_count
    max_count                    = var.system_node_max_count

    # Name of the temporary pool used for rotation when changing properties such as vm_size
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge                     = "33%"
      drain_timeout_in_minutes      = 30
      node_soak_duration_in_minutes = 0
    }

    tags = local.tags
  }

  # Uses Cluster Autoscaler (same family as EKS cluster-autoscaler) → "Manual" mode: you manage the node pools.
  # To use Karpenter-based Node Auto Provisioning, set mode = "Auto" (the node pool autoscaler must then be off).
  # AKS Automatic uses NAP by default → see Lab 10.
  node_provisioning_profile {
    mode = "Manual"
  }

  auto_scaler_profile {
    balance_similar_node_groups   = true # balance node counts across pools in different availability zones
    expander                      = "least-waste"
    skip_nodes_with_local_storage = true # explicitly set to the AKS default (the block makes Terraform send false)
    skip_nodes_with_system_pods   = true
  }

  # --- Maintenance windows: control "when" upgrades happen (no EKS equivalent) ----
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

  # --- Add-ons -------------------------------------------------------------------
  # Secrets Store CSI Driver + Azure Key Vault Provider (≈ AWS Secrets Manager CSI provider)
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # Container Insights (logs): the ama-logs agent sends data to Log Analytics. The DCR is defined in monitoring.tf.
  oms_agent {
    log_analytics_workspace_id      = data.azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  # Managed Prometheus (metrics): the DCR/DCE are defined in monitoring.tf.
  monitor_metrics {}

  # KEDA (event-driven autoscaling) + VPA (requests/limits recommendations)
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
    # Terraform sets the version only at creation time; after that, the AKS auto-upgrade channel manages it.
    # (Through azurerm 5.9, after an automatic patch upgrade the alias "1.36" no longer matches the actual version
    # "1.36.6", so every plan shows a diff. An improvement is planned for 5.10.)
    # For the minor upgrade procedure and how to manage the version directly with Terraform, see Lab 09.
    ignore_changes = [
      kubernetes_version,
      default_node_pool[0].orchestrator_version,
    ]
  }
}

# ---------------------------------------------------------------------------
# User node pool: for application workloads (equivalent to an EKS managed node group)
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
    ignore_changes = [orchestrator_version] # same reason as the cluster (auto-upgrade manages the version)
  }
}

# ---------------------------------------------------------------------------
# (Optional) Spot node pool: for interruptible batch/CI workloads (equivalent to EC2 Spot)
# Scales down to 0 nodes, and pods are scheduled only if they have a toleration.
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.enable_spot_pool ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"

  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = -1 # capped at the on-demand price

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
# Observability wiring: AKS ↔ Managed Prometheus / Container Insights
#
# On AWS (CloudWatch Container Insights, AMP) you wire up "agent + workspace + IAM" yourself,
# whereas on Azure a Data Collection Rule (DCR) defines "what to send where",
# and a Data Collection Rule Association (DCRA) attaches the DCR to the AKS cluster.
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
  description                 = "Managed Prometheus: sends AKS metrics to the Azure Monitor workspace"

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
  description             = "Deleting this stops Prometheus metric collection for this AKS cluster."
}

# The azurerm monitor_metrics block doesn't expose control plane metrics (apiserver, etcd, etc.), so enable them via AzAPI.
# Enable them only after the DCRA has been created, so the collector pods don't go into CrashLoop.
resource "azapi_update_resource" "control_plane_metrics" {
  type        = "Microsoft.ContainerService/managedClusters@2026-05-01"
  resource_id = azurerm_kubernetes_cluster.this.id

  body = {
    properties = {
      azureMonitorProfile = {
        metrics = {
          enabled = true # already on via the monitor_metrics block; the API schema requires it, so it is sent too
          controlPlane = {
            enabled = true
          }
        }
      }
    }
  }

  # A PUT on the same cluster that overlaps with node pool creation/changes fails with 409 AnotherOperationInProgress,
  # so this runs after the node pools.
  depends_on = [
    azurerm_monitor_data_collection_rule_association.prometheus,
    azurerm_kubernetes_cluster_node_pool.user,
    azurerm_kubernetes_cluster_node_pool.spot,
  ]
}

# --- Container Insights (logs) ---------------------------------------------------
locals {
  # Cost-optimized setup: Prometheus handles the performance metrics (Perf, InsightsMetrics),
  # so only the log and inventory streams are collected.
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
  description         = "Container Insights: sends container logs and Kubernetes inventory to Log Analytics"

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

# Container Insights requires the association name to be exactly "ContainerInsightsExtension".
resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
  description             = "Deleting this stops Container Insights log collection for this AKS cluster."
}

# --- Control plane logs (equivalent to EKS control plane logging → CloudWatch Logs) ----
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "diag-to-log-analytics"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated" # use resource-specific tables such as AKSAudit/AKSControlPlane

  dynamic "enabled_log" {
    for_each = toset([
      "kube-audit-admin", # collects audit logs for change (write) operations only: much cheaper than kube-audit
      "kube-apiserver",
      "kube-controller-manager",
      "kube-scheduler",
      "cluster-autoscaler",
      "guard", # Entra ID authentication/authorization logs
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
# Azure Managed Grafana's default Kubernetes dashboards ("Kubernetes / Compute Resources / ...")
# use the time series that the recording rules below pre-compute.
# The portal/CLI creates them automatically when you enable Managed Prometheus,
# but with Terraform you have to define them yourself.
# (Source: AddonTerraformTemplate in the Azure/prometheus-collector repo – Node / Kubernetes rule groups for Linux)
# The rules are long, so just "copy and use this file as is".
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
# Enable Gateway API (the successor standard to Ingress)
#
# Background: community ingress-nginx maintenance ended in 2026-03, and Microsoft security patch support for the
#       AKS "application routing add-on (NGINX)" also ends in 2026-11. The successor is Gateway API,
#       and AKS offers two managed pieces:
#         1) Managed Gateway API CRDs        : AKS installs and upgrades CRDs such as Gateway/HTTPRoute
#         2) approuting-istio implementation : a sidecar-less Istio control plane turns Gateway resources into Envoy proxies
#
# azurerm_kubernetes_cluster in azurerm 5.9 does not expose this setting yet,
# so AzAPI applies it to the cluster as a "partial update".
# (Same approach as the official Microsoft Terraform sample 101-aks-application-routing-gateway-api)
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

  # Runs after control_plane_metrics so that PUTs against the same cluster don't overlap.
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
  # Grants cluster admin permissions to the currently signed-in principal (grant_current_user_admin)
  # plus any additional principals you specify.
  admin_principal_ids = toset(concat(
    var.grant_current_user_admin ? [data.azurerm_client_config.current.object_id] : [],
    tolist(var.admin_principal_ids),
  ))
}

# ---------------------------------------------------------------------------
# Human access to the cluster = Azure RBAC role assignments
#   - Cluster User Role      : permission to fetch a kubeconfig with `az aks get-credentials` (ARM permission)
#   - RBAC Cluster Admin     : permission equivalent to cluster-admin on the Kubernetes API (data plane permission)
# Azure RBAC alone covers what EKS does with its "IAM principal → access entry → access policy" flow.
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
  description = "Cluster resource group"
  value       = azurerm_resource_group.aks.name
}

output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "AKS cluster resource ID"
  value       = azurerm_kubernetes_cluster.this.id
}

output "kubernetes_version" {
  description = "Current control plane version (including patch)"
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "node_resource_group" {
  description = "Resource group where AKS created the node VMSS, load balancer, etc."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  description = "OIDC issuer that Workload Identity federated credentials trust"
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "available_kubernetes_versions" {
  description = "Kubernetes versions supported as GA in this region"
  value       = data.azurerm_kubernetes_service_versions.current.versions
}

output "get_credentials_command" {
  description = "Command that fetches the kubeconfig and converts it to Entra ID sign-in (kubelogin) format"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.aks.name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/05-aks/tests/plan.tftest.hcl" -->
```hcl title="terraform/05-aks/tests/plan.tftest.hcl"
# Test the plan logic only, without Azure: terraform -chdir=terraform/05-aks test
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
    error_message = "Outbound must use the BYO NAT Gateway."
  }

  assert {
    condition     = azurerm_kubernetes_cluster.this.local_account_disabled
    error_message = "Local accounts (static kubeconfig) must be disabled."
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster_node_pool.spot) == 0
    error_message = "With the defaults, there must be no Spot pool."
  }

  assert {
    condition     = length(azapi_update_resource.gateway_api) == 1
    error_message = "With the defaults, Gateway API must be enabled."
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
    error_message = "A Spot pool must be created."
  }

  assert {
    condition     = length(azapi_update_resource.gateway_api) == 0
    error_message = "With enable_gateway_api=false, there must be no azapi update."
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 2
    error_message = "There must be 2 role assignments: 1 additional admin + the current user."
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
    error_message = "With the automatic grant to the current user turned off, only the 1 specified group must be an admin."
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
- 리소스 수: 15개 — 리소스 그룹, 클러스터, User 노드 풀, DCE 1 · DCR 2 · DCRA 2(Prometheus / Container Insights), Prometheus 규칙 그룹 2개, 진단 설정, AzAPI 업데이트 2개, 역할 할당 2개

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
# Lab 05 verification: checks that the AKS cluster was created as designed (read-only).
#   1) A single `az aks show` reads the cluster settings (the equivalent of aws eks describe-cluster)
#   2) kubectl checks nodes · permissions · add-ons. kubeconfig is a temporary file, so ~/.kube/config is left alone.
# Usage: scripts/verify.sh 05-aks
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg name aks nodes ready want zones gc pods p bad sku channel netrg podcidr nsgrules
  rg="$(tf_out 05-aks resource_group_name)"
  name="$(tf_out 05-aks cluster_name)"

  section "05-aks · cluster settings (${name:-?})"
  if [ -z "$name" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 05-aks?"
    return
  fi
  aks="$(azj aks show -g "$rg" -n "$name")"
  if [ -z "$aks" ]; then
    fail "Cluster not found: $name"
    return
  fi

  # --- Status ---
  expect_eq "Provisioning state" "$(jv "$aks" .provisioningState)" "Succeeded"
  expect_eq "Power state" "$(jv "$aks" .powerState.code)" "Running"
  sku="$(jv "$aks" .sku.tier)" # sku_tier variable: Free / Standard (default) / Premium
  case "$sku" in
    Standard | Premium) pass "SKU tier = $sku (includes uptime SLA)" ;;
    Free) warn "SKU tier = Free (no uptime SLA. Unless you changed sku_tier to cut costs, raise it to Standard)" ;;
    *) fail "SKU tier: expected Standard or Premium / actual '${sku:-(none)}'" ;;
  esac
  expect_set "Kubernetes version" "$(jv "$aks" .currentKubernetesVersion)"

  # --- Security / identity ---
  expect_eq "Local accounts (static kubeconfig) disabled" "$(jv "$aks" .disableLocalAccounts)" "true"
  expect_eq "Entra ID integration / Azure RBAC" "$(jv "$aks" '[.aadProfile.managed, .aadProfile.enableAzureRbac] | join("/")')" "true/true"
  expect_eq "OIDC issuer (prerequisite for Workload Identity)" "$(jv "$aks" .oidcIssuerProfile.enabled)" "true"
  expect_eq "Workload Identity" "$(jv "$aks" .securityProfile.workloadIdentity.enabled)" "true"

  # --- Networking ---
  expect_eq "CNI / mode" "$(jv "$aks" '[.networkProfile.networkPlugin, .networkProfile.networkPluginMode] | join("/")')" "azure/overlay"
  expect_eq "Data plane / network policy" "$(jv "$aks" '[.networkProfile.networkDataplane, .networkProfile.networkPolicy] | join("/")')" "cilium/cilium"
  expect_eq "Outbound type (your own NAT Gateway)" "$(jv "$aks" .networkProfile.outboundType)" "userAssignedNATGateway"
  # The 03-network node NSG allows inbound traffic between Pod CIDRs (the subnet NSG also applies to overlay Pod traffic).
  # If the two stacks' pod_cidr values differ, adding a Deny rule to the NSG later would block Pod-to-Pod
  # traffic between nodes (including DNS).
  netrg="$(tf_out 03-network resource_group_name)"
  podcidr="$(jv "$aks" .networkProfile.podCidr)"
  nsgrules=""
  [ -z "$netrg" ] || nsgrules="$(nodes_nsg_rules "$netrg")"
  if [ -z "$nsgrules" ]; then
    skip "Can't read the 03-network node NSG rules; skipping the Pod CIDR allow-rule check"
  else
    jq_ok "Node NSG allows inbound within the Pod CIDR ${podcidr} (pod_cidr is the same in 03-network and 05-aks)" "$nsgrules" \
      "any(.[]; .name == \"AllowPodsToPods\" and .access == \"Allow\" and .sourceAddressPrefix == \"$podcidr\" and .destinationAddressPrefix == \"$podcidr\")"
  fi
  expect_eq "API server VNet Integration" "$(jv "$aks" .apiServerAccessProfile.enableVnetIntegration)" "true"
  if [ "$(jv "$aks" .apiServerAccessProfile.enablePrivateCluster)" = "true" ]; then
    pass "Private cluster (API server reachable only from inside the VNet)"
  else
    jq_ok "API server authorized IP ranges set" "$aks" '(.apiServerAccessProfile.authorizedIpRanges | length) >= 1'
  fi

  # --- Upgrades / add-ons ---
  expect_eq "Node OS upgrade channel" "$(jv "$aks" .autoUpgradeProfile.nodeOsUpgradeChannel)" "NodeImage"
  channel="$(jv "$aks" .autoUpgradeProfile.upgradeChannel)" # Default: patch. Other values are expected after Lab 09 approach A / C-1.
  case "$channel" in
    patch) pass "Auto-upgrade channel = patch (default setup)" ;;
    none | stable | rapid | node-image) pass "Auto-upgrade channel = $channel (changed from the default value patch - Lab 09)" ;;
    *) fail "Auto-upgrade channel: expected patch (or none/stable/rapid/node-image) / actual '${channel:-(none)}'" ;;
  esac
  jq_ok "Azure Policy add-on" "$aks" '.addonProfiles.azurepolicy.enabled == true'
  jq_ok "Container Insights (ama-logs)" "$aks" '.addonProfiles.omsagent.enabled == true or .azureMonitorProfile.containerInsights.enabled == true'
  jq_ok "Key Vault Secrets Store CSI driver" "$aks" '.addonProfiles.azureKeyvaultSecretsProvider.enabled == true'
  jq_ok "Managed Prometheus (ama-metrics)" "$aks" '.azureMonitorProfile.metrics.enabled == true'
  jq_ok "KEDA / VPA" "$aks" '.workloadAutoScalerProfile.keda.enabled == true and .workloadAutoScalerProfile.verticalPodAutoscaler.enabled == true'

  # --- Node pools ---
  jq_ok "System pool: autoscaling + ephemeral OS disk" "$aks" \
    '.agentPoolProfiles[] | select(.name == "system") | .mode == "System" and .enableAutoScaling == true and .osDiskType == "Ephemeral"'
  jq_ok "User pool: autoscaling" "$aks" \
    '.agentPoolProfiles[] | select(.name == "user") | .mode == "User" and .enableAutoScaling == true'
  expect_ge "System pool availability zone count" "$(jv "$aks" '.agentPoolProfiles[] | select(.name == "system") | .availabilityZones | length')" 2

  # --- kubectl ---
  section "05-aks · kubectl checks"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin not found; skipping"
    return
  fi
  if ! kube_login "$rg" "$name"; then
    fail "Couldn't get the kubeconfig (check az login and the 'Azure Kubernetes Service Cluster User Role' role)"
    return
  fi
  nodes="$(kj get nodes)"
  if [ -z "$nodes" ]; then
    if [ "$(jv "$aks" .apiServerAccessProfile.enablePrivateCluster)" = "true" ]; then
      skip "Can't reach the private cluster's API server; skipping kubectl checks (re-run from a jump host or VPN inside the VNet)"
    else
      fail "Couldn't reach the API server. If your public IP changed, update TF_VAR_allowed_ip_ranges and apply 05-aks."
    fi
    return
  fi
  ready="$(jv "$nodes" '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
  # An autoscaled pool never goes below minCount, so the baseline is the sum of each pool's
  # minimum node count (default: system 3 + user 3).
  want="$(jv "$aks" '[.agentPoolProfiles[] | if .enableAutoScaling == true then (.minCount // 0) else (.count // 0) end] | add')"
  expect_ge "Ready nodes (sum of per-pool minimum node counts)" "$ready" "${want:-1}"
  zones="$(jv "$nodes" '[.items[].metadata.labels["topology.kubernetes.io/zone"]] | unique | length')"
  expect_ge "Availability zones the nodes are spread across" "$zones" 2

  if [ "$(kubectl --request-timeout=20s auth can-i '*' '*' 2>/dev/null)" = "yes" ]; then
    pass "cluster-admin permission (Azure RBAC Cluster Admin)"
  else
    fail "No cluster-admin permission (role propagation can take up to 5 min; check grant_current_user_admin / admin_principal_ids)"
  fi

  if [ "$(jv "$aks" '(.ingressProfile.gatewayApi // .ingressProfile.gatewayAPI // {}).installation')" = "Standard" ]; then
    gc="$(kj get gatewayclass approuting-istio)"
    jq_ok "GatewayClass approuting-istio is Accepted" "$gc" '.status.conditions[]? | select(.type == "Accepted") | .status == "True"'
  else
    skip "Gateway API is off; skipping the GatewayClass check (enable_gateway_api = false)"
  fi

  pods="$(kj get pods -n kube-system)"
  for p in ama-logs ama-metrics cilium coredns; do
    jq_ok "kube-system: $p pod Running" "$pods" "[.items[] | select((.metadata.name | startswith(\"$p\")) and .status.phase == \"Running\")] | length >= 1"
  done
  bad="$(kj get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded)"
  jq_warn "No pods other than Running/Completed" "$bad" '(.items | length) == 0'
}

# You can also run it directly (scripts/verify/05-aks.sh).
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
