<!-- lang-switch -->
[English](../10-aks-automatic.md) | **한국어**
<!-- /lang-switch -->

# Lab 10. AKS Automatic: EKS Auto Mode 에 해당하는 "운영까지 맡기는" 모드

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 30분 (apply 10–15분) | AKS Standard 티어 + 자동 프로비저닝 노드 (실습 후 바로 삭제) | `terraform/10-aks-automatic` | [02. 원격 State](02-bootstrap.md) (Lab 03–05 와 독립) |

> [!NOTE]
> 2026 년 현재 Microsoft 의 Well-Architected 가이드는 *"대부분의 신규 프로덕션 워크로드에는 AKS Automatic 을 선택하고, Windows 노드·LTS·특수한 네트워크/플랫폼 커스터마이징이 필요할 때만 Standard 를 선택하라"* 고 권장합니다. Lab 05 에서 직접 설계한 것을 이 모드는 **기본값으로 제공**합니다.

## 이번 실습에서 만드는 것

Lab 05 에서 약 250 줄의 `cluster.tf` 와 모니터링/네트워크 설정으로 만든 것을, **약 20 줄**의 리소스로 만듭니다.

```text
 azurerm_kubernetes_automatic_cluster
  ├─ 관리형 시스템 노드 풀 (AKS 구독에서 호스팅/운영)      ← Standard 에서는 직접 생성
  ├─ Node Auto Provisioning (Karpenter 기반) 사용자 노드    ← 파드 요구사항에 맞는 VM 을 자동 선택
  ├─ Azure CNI Overlay + Cilium, 관리형 NAT Gateway
  ├─ Entra ID + Azure RBAC (로컬 계정 없음), Workload Identity/OIDC
  ├─ Deployment Safeguards + Pod Security Standards(baseline) enforce
  └─ approuting-istio(Gateway API 구현; CRD 는 1.36+ 에서 기본 포함), Standard 티어 + Pod readiness SLA(99.9% / 5분), 자동 업그레이드(stable, N-1)
```

## AWS 경험자를 위한 비교

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| EKS Auto Mode | **AKS Automatic** | 둘 다 노드·스케일·업그레이드·주요 애드온을 운영 주체가 관리합니다. |
| Auto Mode 가 만드는 EC2 (내 계정에 보임) | **관리형 시스템 노드 풀**은 AKS 구독에서 호스팅 | 시스템 노드는 내 구독의 VM 목록에 보이지 않습니다. |
| Karpenter NodePool/EC2NodeClass | NAP 의 `NodePool` / `AKSNodeClass` CRD | 같은 Karpenter 계열 API. |
| Pod Security/Kyverno 직접 구성 | **Deployment Safeguards** (Azure Policy, enforce) | 리소스 요청/제한, probe, `latest` 태그 금지 등 위반 시 배포 거부. |
| 노드 관리 계정의 EC2 직접 수정 가능 | **노드 리소스 그룹 잠금** (`MC_` 수정 불가) | 실수로 노드를 건드리는 일을 방지. |

## Standard vs Automatic: 무엇을 고를까

![AKS Standard 와 AKS Automatic: 누가 운영하나](diagrams/standard-vs-automatic.svg)

| 영역 | AKS Automatic | AKS Standard (Lab 05) |
|---|---|---|
| 시스템 노드 풀 | 관리형(AKS 가 운영) | 직접 생성/운영 |
| 노드 스케일링 | **NAP 고정**, HPA/KEDA/VPA 활성 | Cluster Autoscaler 또는 NAP 선택 |
| 티어 / SLA | Standard + **Pod readiness SLA** + 업타임 SLA | Free(기본) / Standard / Premium(LTS) |
| 업그레이드 | `stable` 채널(N-1) + 노드 이미지 자동 | 수동 또는 채널 선택 |
| 인증 | Azure RBAC 고정 (로컬 계정 없음) | 로컬 계정 기본 → 끄기 권장 |
| 정책 | Deployment Safeguards + PSS baseline **enforce** | 선택 (Lab 08) |
| 네트워크 | Overlay + Cilium, 관리형 NAT, API 서버 VNet Integration | 선택 (Lab 03/05 에서 직접 구성) |
| 관측성 | 포털/CLI 로 만들면 Prometheus/Container Insights 기본 → **Terraform 으로 만들 때는 직접 연결** | 직접 구성 (Lab 05 의 DCR 패턴) |
| 제약 | Windows 노드 없음, 일부 확장 미지원(Dapr 등), **Standard → Automatic 전환 불가** | 거의 없음 |

> [!IMPORTANT]
> **Standard 에서 Automatic 으로 이전(in-place 변환)은 지원되지 않습니다.** 처음부터 어느 쪽을 쓸지 정하세요. 판단이 어렵다면 Automatic 으로 시작해 부족한 점을 확인하는 것이 권장 순서입니다.

## 설계 결정 (Best practice)

| 결정 | 이유 |
|---|---|
| 기본은 **managed VNet** (`use_byo_network = false`) | 가장 단순. 기존 네트워크/온프레미스 연동이 필요하면 BYO VNet 으로 시작해야 합니다(이후 변경 불가). |
| BYO 시: 서브넷 3개(API 서버 위임 /28, user 노드, system 노드) + **UAMI + VNet 에 Network Contributor** | Microsoft 공식 샘플과 동일한 요구 사항. NAP 가 VNet 안에서 노드를 만들기 때문에 VNet 범위 권한이 필요. |
| system 노드 서브넷의 `ignore_changes = [delegation]` | AKS 가 클러스터 생성 후 서브넷에 위임을 추가해 Terraform 이 되돌리려는 것을 막습니다. |
| Ingress: `web_app_routing_ingress { istio_enabled = true }` | NGINX 대신 approuting-istio 구현. Gateway API CRD 까지 기본 포함되는 것은 1.36+ 신규 Automatic 입니다(`stable` 채널은 N-1 이라 지금은 1.35 로 만들어져 CRD 가 없을 수 있습니다). |
| `api_server_access.authorized_ip_ranges` | 공용 엔드포인트는 내 IP 만. |
| 관리자 권한: `grant_current_user_admin` / `admin_principal_ids` | Automatic 은 로컬 계정이 없어 Azure RBAC 역할이 유일한 접근 수단입니다. 실습은 현재 로그인 사용자에게 부여(기본), 팀/CI 는 `false` 로 끄고 Entra 그룹 Object ID 를 `admin_principal_ids` 로 지정하세요(둘 다 비우면 `validation` 이 막습니다). |

## 코드

<!-- tf:include path="terraform/10-aks-automatic/versions.tf" -->
```hcl title="terraform/10-aks-automatic/versions.tf"
terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "10-aks-automatic.tfstate"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/10-aks-automatic/providers.tf" -->
```hcl title="terraform/10-aks-automatic/providers.tf"
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

<!-- tf:include path="terraform/10-aks-automatic/variables.tf" -->
```hcl title="terraform/10-aks-automatic/variables.tf"
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
  description = "Azure region (must be a region that supports AKS Automatic; koreacentral is supported)"
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
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "Specify at least one CIDR in allowed_ip_ranges. Example: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "grant_current_user_admin" {
  description = <<-EOT
    If true, grants cluster admin permissions (Azure RBAC Cluster Admin) to the "currently signed-in principal"
    that runs terraform. This is the lab default.
    In team/CI environments, set it to false and specify an Entra group in admin_principal_ids.
  EOT
  type        = bool
  default     = true

  validation {
    condition     = var.grant_current_user_admin || length(var.admin_principal_ids) > 0
    error_message = "When grant_current_user_admin = false, specify at least one admin group/user in admin_principal_ids. (AKS Automatic has no local accounts, so with no admin, nobody can access the cluster.)"
  }
}

variable "admin_principal_ids" {
  description = "Object IDs of additional Entra users/groups to grant cluster admin permissions (Azure RBAC Cluster Admin). In team environments, prefer groups over individuals."
  type        = set(string)
  default     = []
}

variable "use_byo_network" {
  description = <<-EOT
    false (default): "managed VNet" mode where AKS manages the VNet too - the simplest option.
    true           : use your own VNet/subnets (BYO VNet) - when you need to integrate with an existing network/on-premises.
  EOT
  type        = bool
  default     = false
}

variable "vnet_cidr" {
  description = "Address space of the VNet to create when use_byo_network = true"
  type        = string
  default     = "10.20.0.0/16"
}
```
<!-- /tf:include -->

**`main.tf`** — 리소스 그룹과 (선택) BYO VNet

<!-- tf:include path="terraform/10-aks-automatic/main.tf" -->
```hcl title="terraform/10-aks-automatic/main.tf"
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
```
<!-- /tf:include -->

**`cluster.tf`** — Automatic 클러스터: Lab 05 의 `cluster.tf` 와 비교해 보세요.

<!-- tf:include path="terraform/10-aks-automatic/cluster.tf" -->
```hcl title="terraform/10-aks-automatic/cluster.tf"
# ---------------------------------------------------------------------------
# AKS Automatic  (the "we operate it for you" mode, equivalent to Amazon EKS Auto Mode)
#
# Most of the settings you configured by hand in 05-aks are "preconfigured" here, so the code is much shorter.
#   - Managed system node pool, Node Auto Provisioning (Karpenter-based) node autoscaling
#   - Azure CNI Overlay + Cilium, egress through a managed NAT Gateway
#   - Standard tier (uptime SLA) + Pod readiness SLA, auto upgrades (stable channel, N-1), automatic node image replacement
#   - Entra ID + Azure RBAC (no local accounts), Workload Identity/OIDC, Deployment Safeguards, image cleaner
#   - HPA / KEDA / VPA, node auto-repair, node resource group lockdown
#
# Note: Managed Prometheus / Container Insights are enabled by default only when you create the cluster with the
#       Azure CLI or the portal. This cluster, created with Terraform, is not connected to them, so connect them
#       yourself if you need them (as in 05-aks/monitoring.tf).
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_automatic_cluster" "this" {
  name                = module.naming.names.aks_automatic
  location            = azurerm_resource_group.automatic.location
  resource_group_name = azurerm_resource_group.automatic.name

  # managed VNet: SystemAssigned is enough. BYO VNet: needs a UserAssigned identity that was granted permissions beforehand.
  identity {
    type         = local.byo ? "UserAssigned" : "SystemAssigned"
    identity_ids = local.byo ? [azurerm_user_assigned_identity.aks[0].id] : null
  }

  api_server_access {
    authorized_ip_ranges = var.allowed_ip_ranges
    subnet_id            = local.byo ? azurerm_subnet.api_server[0].id : null
  }

  dynamic "hosted_system" {
    for_each = local.byo ? [1] : []

    content {
      node_subnet_id        = azurerm_subnet.user_nodes[0].id
      system_node_subnet_id = azurerm_subnet.system_nodes[0].id
    }
  }

  # Ingress: Gateway API implementation (approuting-istio) instead of NGINX.
  # Same as the default for new Automatic clusters on AKS 1.36+.
  web_app_routing_ingress {
    istio_enabled = true
  }

  tags = local.tags

  depends_on = [azurerm_role_assignment.network_contributor]
}

# Automatic uses only Azure RBAC, so people need role assignments too.
# Grant them to the currently signed-in principal (grant_current_user_admin) and to the principals listed in
# admin_principal_ids (an Entra group is recommended in team environments).
locals {
  admin_principal_ids = toset(concat(
    var.grant_current_user_admin ? [data.azurerm_client_config.current.object_id] : [],
    tolist(var.admin_principal_ids),
  ))
}

resource "azurerm_role_assignment" "cluster_user" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_automatic_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_automatic_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/10-aks-automatic/outputs.tf" -->
```hcl title="terraform/10-aks-automatic/outputs.tf"
output "cluster_name" {
  description = "AKS Automatic cluster name"
  value       = azurerm_kubernetes_automatic_cluster.this.name
}

output "resource_group_name" {
  description = "Cluster resource group"
  value       = azurerm_resource_group.automatic.name
}

output "kubernetes_version" {
  description = "Current Kubernetes version (managed automatically by AKS through the stable channel)"
  value       = azurerm_kubernetes_automatic_cluster.this.current_kubernetes_version
}

output "get_credentials_command" {
  description = "Get the kubeconfig and convert it for kubelogin"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.automatic.name} --name ${azurerm_kubernetes_automatic_cluster.this.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/10-aks-automatic/tests/plan.tftest.hcl" -->
```hcl title="terraform/10-aks-automatic/tests/plan.tftest.hcl"
# Verify only the plan logic, without Azure: terraform -chdir=terraform/10-aks-automatic test
mock_provider "azurerm" {
  source = "../mocks"
}

variables {
  allowed_ip_ranges = ["203.0.113.10/32"]
}

run "plan_managed_vnet" {
  command = plan

  assert {
    condition     = length(azurerm_virtual_network.byo) == 0
    error_message = "The default (managed VNet) does not create a VNet."
  }
}

run "plan_group_admin_only" {
  command = plan

  variables {
    grant_current_user_admin = false
    admin_principal_ids      = ["22222222-2222-2222-2222-222222222222"]
  }

  assert {
    condition     = length(azurerm_role_assignment.cluster_admin) == 1 && length(azurerm_role_assignment.cluster_user) == 1
    error_message = "With the automatic grant to the current user turned off, only the one specified group must be an admin."
  }
}

run "rejects_cluster_without_admin" {
  command = plan

  variables {
    grant_current_user_admin = false
  }

  expect_failures = [var.grant_current_user_admin]
}

run "plan_byo_vnet" {
  command = plan

  variables {
    use_byo_network = true
  }

  assert {
    condition     = length(azurerm_subnet.api_server) == 1 && azurerm_subnet.api_server[0].address_prefixes[0] == "10.20.0.0/28"
    error_message = "The API server subnet must be a /28."
  }
}
```
<!-- /tf:include -->

## 실습 따라하기

### 1단계. 적용

```bash
cd terraform/10-aks-automatic
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan
terraform apply tfplan            # 10~15분
eval "$(terraform output -raw get_credentials_command)"
```

> [!NOTE]
> AKS Automatic 은 Azure Policy 를 자동으로 켭니다. 구독에 `Microsoft.PolicyInsights` RP 가 등록되어 있어야 합니다([Lab 01](01-prerequisites.md)).
> Azure CLI 의 `aks-preview` 확장이 설치되어 있다면 충돌할 수 있으니 `az extension remove -n aks-preview` 를 권장합니다.

> [!IMPORTANT]
> **이제 클러스터가 2개입니다.** `az aks get-credentials` 가 이 Automatic 클러스터를 `kubectl` 의 현재 컨텍스트로 바꾸므로, 다음 단계의 명령은 모두 이 클러스터로 갑니다. Lab 05 클러스터로 돌아가려면 `kubectl config use-context <이름>` 을 쓰세요. `kubectl config get-contexts` 가 둘을 보여 주고, `az aks list -o table` 의 SKU 로 구분합니다(Standard 는 `Base`, 이 클러스터는 `Automatic`). [부록 D](99-appendix.md) 를 참고하세요. 이 클러스터는 Lab 04 의 ACR 과 연결되어 있지 않으므로 여기서는 공개 이미지를 쓰세요.

### 2단계. 노드가 "없는" 클러스터를 확인

```bash
kubectl get nodes              # 처음에는 사용자 노드가 없거나 적습니다 (관리형 hostedpool 노드 3개 + system-surge 노드 1개가 보입니다)
kubectl get nodepools.karpenter.sh 2>/dev/null     # NAP 의 NodePool (default, system-surge)
kubectl get gatewayclass       # approuting-istio (Gateway API CRD 가 있는 1.36+ 클러스터에서만)

# 아웃바운드: AKS 가 노드 리소스 그룹에 만든 NAT Gateway 의 공인 IP 가 이 클러스터의 출구 IP 입니다
NODE_RG=$(az aks show -g "$(terraform output -raw resource_group_name)" -n "$(terraform output -raw cluster_name)" --query nodeResourceGroup -o tsv)
az network public-ip list -g "$NODE_RG" --query "[].ipAddress" -o tsv
```

> [!TIP]
> 클러스터 안에서 이 주소를 직접 확인하려면 [부록 D](99-appendix.md)(D-2)의 파드를 실행하세요. 리소스 요청이 없는 단독 `kubectl run` 파드는 여기서 거부됩니다.

> [!NOTE]
> 새 Automatic 클러스터는 `stable` 채널(N-1)이라 **GA 최신 minor 보다 한 단계 낮은 버전**(2026-10 기준 1.35.8)으로 만들어지고, `azurerm_kubernetes_automatic_cluster` 에서는 버전을 고를 수 없습니다. 이 경우 `istio_enabled = true` 로 approuting-istio 구현은 켜지지만 Gateway API CRD 는 설치되지 않아 `kubectl get gatewayclass` 가 `the server doesn't have a resource type "gatewayclass"` 로 실패합니다(정상). Gateway/HTTPRoute 를 쓰려면 1.36+ 로 올라간 뒤에 확인하세요.

### 3단계. Deployment Safeguards 체험

보호 장치 없이 만든 배포는 거부(또는 경고)됩니다.

```bash
kubectl create deployment naive --image=mcr.microsoft.com/dotnet/samples:aspnetapp --replicas=2
# → 리소스 요청/제한, probe 등 Deployment Safeguards 위반 메시지가 표시됩니다
```

Best practice 를 지킨 배포는 통과하고, 대기 중 파드가 **NAP 가 새 노드를 만들도록** 유도합니다.

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: hello, namespace: default }
spec:
  replicas: 3
  selector: { matchLabels: { app: hello } }
  template:
    metadata: { labels: { app: hello } }
    spec:
      containers:
      - name: hello
        image: mcr.microsoft.com/dotnet/samples:aspnetapp
        ports: [{ containerPort: 8080 }]
        resources:
          requests: { cpu: 500m, memory: 256Mi }
          limits:   { cpu: "1",  memory: 512Mi }
        readinessProbe: { httpGet: { path: /, port: 8080 } }
        livenessProbe:  { httpGet: { path: /, port: 8080 } }
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 1654
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
EOF

kubectl get pods -w                       # Pending → NAP 가 노드 프로비저닝 → Running (보통 1~3분)
kubectl get nodeclaims 2>/dev/null        # NAP 가 요청한 VM (Karpenter NodeClaim)
kubectl get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
```

파드 요구사항(CPU/메모리)에 맞는 VM 크기가 **자동 선택**됩니다. Lab 05 에서는 노드 풀의 `vm_size`, `min/max` 를 직접 정했던 부분입니다.

### 4단계. (선택) BYO VNet 으로 새로 만들어 보기

```bash
terraform destroy                                  # 기존 클러스터 정리 (VNet 모드는 도중 전환 불가)
terraform apply -var use_byo_network=true          # VNet + 서브넷 3개 + UAMI + 역할 할당 + 클러스터
```

### 5단계. 정리

```bash
kubectl delete deployment hello naive --ignore-not-found
terraform destroy
```

### 자동 검증 스크립트

AKS Automatic 설정(SKU, NAP, 로컬 계정, 업그레이드 채널)과 노드/Karpenter NodePool 을 확인합니다 (읽기 전용).

```bash
cd ../..                          # 저장소 루트에서 실행
scripts/verify.sh 10-aks-automatic
```

<!-- tf:include path="scripts/verify/10-aks-automatic.sh" -->
```bash title="scripts/verify/10-aks-automatic.sh"
#!/usr/bin/env bash
# Lab 10 verification: checks that the AKS Automatic cluster was created in the "we operate it for you" mode (read-only).
#   AWS comparison: EKS Auto Mode (the cloud manages nodes · scaling · upgrades · security defaults)
# Usage: scripts/verify.sh 10-aks-automatic
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg name aks nodes ready pools
  rg="$(tf_out 10-aks-automatic resource_group_name)"
  name="$(tf_out 10-aks-automatic cluster_name)"

  section "10-aks-automatic · cluster settings (${name:-?})"
  if [ -z "$name" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 10-aks-automatic?"
    return
  fi
  aks="$(azj aks show -g "$rg" -n "$name")"
  if [ -z "$aks" ]; then
    fail "Cluster not found: $name"
    return
  fi

  expect_eq "Provisioning state" "$(jv "$aks" .provisioningState)" "Succeeded"
  expect_eq "SKU (name / tier)" "$(jv "$aks" '[.sku.name, .sku.tier] | join("/")')" "Automatic/Standard"
  expect_eq "Node provisioning (NAP = Karpenter-based)" "$(jv "$aks" .nodeProvisioningProfile.mode)" "Auto"
  expect_eq "Local accounts disabled (Azure RBAC only)" "$(jv "$aks" .disableLocalAccounts)" "true"
  expect_eq "Azure RBAC" "$(jv "$aks" .aadProfile.enableAzureRbac)" "true"
  expect_eq "CNI / data plane" "$(jv "$aks" '[.networkProfile.networkPluginMode, .networkProfile.networkDataplane] | join("/")')" "overlay/cilium"
  expect_eq "Auto-upgrade channel" "$(jv "$aks" .autoUpgradeProfile.upgradeChannel)" "stable"
  expect_eq "OIDC issuer / Workload Identity" "$(jv "$aks" '[.oidcIssuerProfile.enabled, .securityProfile.workloadIdentity.enabled] | join("/")')" "true/true"

  section "10-aks-automatic · kubectl checks"
  if ! require_cmd kubectl kubelogin; then
    skip "kubectl/kubelogin not found; skipping"
    return
  fi
  if ! kube_login "$rg" "$name"; then
    fail "Couldn't get the kubeconfig (check az login and the Cluster User Role)"
    return
  fi
  nodes="$(kj get nodes)"
  if [ -z "$nodes" ]; then
    fail "Couldn't reach the API server. If your public IP changed, update TF_VAR_allowed_ip_ranges and apply."
    return
  fi
  ready="$(jv "$nodes" '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
  expect_ge "Ready nodes (managed system pool)" "$ready" 1

  # NAP creates nodes through Karpenter NodePools (the same concept as NodePools in EKS Auto Mode).
  pools="$(kj get nodepools.karpenter.sh)"
  jq_warn "Karpenter NodePool exists (NAP)" "$pools" '(.items | length) >= 1'
}

# You can also run it directly (scripts/verify/10-aks-automatic.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `Location is not supported` | Automatic 지원 리전인지 확인 (`koreacentral`, `koreasouth` 등 지원). |
| `MissingSubscriptionRegistration ... PolicyInsights` | `az provider register -n Microsoft.PolicyInsights`. |
| 파드가 계속 `Pending` | vCPU 쿼터 부족(NAP 가 VM 패밀리를 자동 선택). 쿼터 확인 후 증설, `kubectl describe pod` 와 `kubectl get nodeclaims` 확인. |
| `Forbidden` (kubectl) | Azure RBAC 역할 전파 대기(최대 5분). Automatic 은 로컬 계정이 없습니다. `grant_current_user_admin = false` 라면 본인/소속 그룹이 `admin_principal_ids` 에 있는지 확인. |
| BYO 에서 `LinkedAuthorizationFailed` | UAMI 의 Network Contributor 전파 지연 → 재시도. |

다음 → [Lab 11. 정리](11-cleanup.md)
