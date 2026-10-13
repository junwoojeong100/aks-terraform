# Lab 04. 플랫폼 서비스: ACR · Key Vault · 모니터링 · AKS 용 ID

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 30분 | ACR Premium + Managed Grafana + Private Endpoint (시간당 약 $0.2–0.3) | `terraform/04-platform` | [03. 네트워크](03-network.md) |

## 이번 실습에서 만드는 것

클러스터가 "의존하는" 공용 서비스와 **AKS 가 사용할 Managed Identity 2개**를 클러스터보다 먼저 만듭니다.

```text
 rg-aksdemo-dev-krc-platform
 ├── id-aks-…-cluster   (UAMI)  컨트롤 플레인 ID  ── Network Contributor(네트워크 RG), Managed Identity Operator(kubelet ID)
 ├── id-aks-…-kubelet   (UAMI)  노드 ID           ── AcrPull(ACR)
 ├── acr…               (ACR Premium, 영역 중복)  ── Private Endpoint(snet-private-endpoints) + 공용은 내 IP 만
 ├── kv-…               (Key Vault, RBAC)         ── Private Endpoint + 공용은 내 IP 만
 ├── log-…              (Log Analytics)           ← 로그/컨트롤 플레인 진단 로그
 ├── amw-…              (Azure Monitor workspace) ← Managed Prometheus 메트릭
 └── amg-…              (Managed Grafana)         ── Prometheus 데이터 소스 자동 연결
```

## AWS 경험자를 위한 비교

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| ECR | `azurerm_container_registry` (ACR) | Private Endpoint·IP 방화벽·영역 중복은 **Premium**. 노드 pull 은 `AcrPull` 역할. `admin_enabled = false`. |
| ECR 라이프사이클 정책 | `retention_policy_in_days` (untagged 매니페스트) | Premium 기능. |
| EKS cluster role / node role | **UAMI 2개** + 역할 할당 | AWS 는 role 에 신뢰 정책 + 권한 정책을 붙이지만, Azure 는 "ID 리소스 → 대상 리소스에 역할 할당" 입니다. |
| KMS + Secrets Manager + ACM | `azurerm_key_vault` | `rbac_authorization_enabled = true` → IAM 과 동일한 RBAC 모델. 5.x 에서 **필수 인수**. |
| VPC Endpoint (Interface) | `azurerm_private_endpoint` + `private_dns_zone_group` | Lab 03 의 Private DNS Zone 에 A 레코드가 자동 등록됩니다. |
| CloudWatch Logs | Log Analytics workspace | KQL 로 질의. 일일 수집 상한(`daily_quota_gb`)으로 비용 폭주 방지. |
| Amazon Managed Prometheus (AMP) | `azurerm_monitor_workspace` | Prometheus 원격 쓰기/쿼리 호환. 수집 설정은 Lab 05 의 DCR/DCRA. |
| Amazon Managed Grafana (AMG) | `azurerm_dashboard_grafana` | Grafana 로그인은 Entra ID. **Grafana Admin** 역할을 할당해야 대시보드를 볼 수 있습니다. |

> [!TIP]
> **왜 UAMI 를 직접 만들까?** AKS 는 System-assigned ID 도 지원하지만, UAMI 를 미리 만들어 **역할 할당을 먼저 끝내 두면** 클러스터 생성 중 권한 전파 지연으로 실패하는 일을 줄이고, 클러스터를 재생성해도 ID/권한이 유지됩니다. kubelet ID 를 분리하면 ACR 권한도 클러스터 생성 전에 끝낼 수 있습니다.

### 역할 할당 한눈에 보기

| 주체 | 역할 | 범위(scope) | 이유 |
|---|---|---|---|
| cluster UAMI | Network Contributor | 네트워크 RG | 서브넷 join, NAT Gateway 사용, 내부 LB IP 할당 |
| cluster UAMI | Managed Identity Operator | kubelet UAMI | 노드에 kubelet ID 부착 |
| kubelet UAMI | AcrPull | ACR | 이미지 pull |
| 실습자(현재 사용자) | AcrPush | ACR | 이미지 push / import (`grant_current_user_roles`, 팀/CI 에서는 `false` 로 끄고 그룹/CI 주체에 별도 부여) |
| Grafana MI | Monitoring Data Reader | Azure Monitor workspace | Prometheus 쿼리 |
| 실습자 | Grafana Admin | Grafana | 대시보드 로그인 (`grant_current_user_roles`) |

## 설계 결정 (Best practice)

| 결정 | 이유 |
|---|---|
| ACR/Key Vault 를 **Private Endpoint + 공용 엔드포인트는 내 IP(와 신뢰된 Azure 서비스)만 허용(기본 Deny)** | 노드·파드는 사설 경로로만 접근. 관리자 PC/CI 는 IP 허용으로 `az acr import`, 시크릿 생성 가능. 방화벽의 "신뢰된 Azure 서비스 허용"(Key Vault `bypass = "AzureServices"`, ACR `network_rule_bypass_option` 기본값 `AzureServices`)은 켜져 있으므로, 완전히 막으려면 `"None"` 으로 바꾸세요. 운영에서는 CI 러너를 VNet 안에 두고 공용 접근을 완전히 끕니다. |
| Key Vault **purge protection + soft delete 7일** | 실수 삭제 방지. 단, `destroy` 후 이름이 7일 점유(같은 이름으로 재생성하면 provider 가 복구) → Lab 11. |
| Key Vault IP 규칙에서 `/32` 제거 | Key Vault 는 `/31`, `/32` 를 받지 않고 단일 IP 로 써야 합니다 (`replace(cidr, "/32", "")`). |
| ACR `admin_enabled = false`, `anonymous_pull_enabled = false` | 정적 자격 증명/익명 접근 제거. |
| Log Analytics `local_authentication_enabled = false` | 공유 키 대신 Entra(관리 ID) 인증만 허용. |
| 진단 설정(Diagnostic settings) 으로 ACR/Key Vault 감사 로그 수집 | CloudTrail 데이터 이벤트와 같은 역할. |

## 코드

<!-- tf:include path="terraform/04-platform/versions.tf" -->
```hcl title="terraform/04-platform/versions.tf"
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
    key              = "04-platform.tfstate"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/providers.tf" -->
```hcl title="terraform/04-platform/providers.tf"
provider "azurerm" {
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }

    key_vault {
      # 이름이 같은 soft-deleted Key Vault 가 있으면 새로 만들지 않고 복구합니다.
      recover_soft_deleted_key_vaults = true
      purge_soft_delete_on_destroy    = false
    }

    log_analytics_workspace {
      # 실습 후 같은 이름으로 다시 만들 수 있도록 destroy 시 영구 삭제합니다.
      permanently_delete_on_destroy = true
    }
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/variables.tf" -->
```hcl title="terraform/04-platform/variables.tf"
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
    ACR / Key Vault 방화벽에서 허용할 관리자 공인 IP (CIDR 목록).
    예: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
    노드/파드는 Private Endpoint 로 접근하므로 이 목록은 "사람/CI" 용입니다.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "allowed_ip_ranges 에 CIDR 을 1개 이상 지정하세요. 예: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "enable_grafana" {
  description = "Azure Managed Grafana 생성 여부 (Standard SKU 는 시간당 요금이 발생합니다)."
  type        = bool
  default     = true
}

variable "grant_current_user_roles" {
  description = <<-EOT
    true 이면 terraform 을 실행하는 "현재 로그인 주체"에게 실습용 역할(ACR 에 AcrPush, Grafana 에 Grafana Admin)을 부여합니다.
    팀/CI 환경에서는 false 로 두고, 사람은 Entra 그룹 / CI 는 별도 서비스 주체에 역할을 부여하세요.
  EOT
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Log Analytics 보존 기간(일)"
  type        = number
  default     = 30
}

variable "log_daily_quota_gb" {
  description = "Log Analytics 일일 수집 상한(GB). 실습 비용 폭주를 막는 안전장치입니다. -1 이면 무제한."
  type        = number
  default     = 5
}

variable "key_vault_purge_protection_enabled" {
  description = "Key Vault 제거 방지(purge protection). 운영에서는 true 를 권장하며, 한 번 켜면 끌 수 없습니다."
  type        = bool
  default     = true
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/main.tf" -->
```hcl title="terraform/04-platform/main.tf"
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

  # Key Vault IP 규칙은 /31, /32 접두사를 받지 않으므로 단일 IP 로 변환합니다.
  key_vault_ip_rules = [for cidr in var.allowed_ip_ranges : replace(cidr, "/32", "")]
}

# ---------------------------------------------------------------------------
# 03-network 스택이 만든 리소스를 "이름 규칙"으로 조회합니다.
# AWS 의 `data "aws_vpc"` + 태그 조회와 같은 방식이며, remote state 의존성이 없습니다.
# ---------------------------------------------------------------------------
data "azurerm_resource_group" "network" {
  name = module.naming.names.rg_network
}

data "azurerm_virtual_network" "this" {
  name                = module.naming.names.vnet
  resource_group_name = module.naming.names.rg_network
}

data "azurerm_subnet" "private_endpoints" {
  name                 = module.naming.names.snet_private_endpoint
  virtual_network_name = module.naming.names.vnet
  resource_group_name  = module.naming.names.rg_network
}

data "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = module.naming.names.rg_network
}

data "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = module.naming.names.rg_network
}

# ---------------------------------------------------------------------------
# 플랫폼(공용 서비스) 리소스 그룹
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "platform" {
  name     = module.naming.names.rg_platform
  location = var.location
  tags     = local.tags
}
```
<!-- /tf:include -->

**`identity.tf`** — AKS 가 쓸 UAMI 와 역할 할당

<!-- tf:include path="terraform/04-platform/identity.tf" -->
```hcl title="terraform/04-platform/identity.tf"
# ---------------------------------------------------------------------------
# AKS 가 사용할 Managed Identity 두 개 (cluster / kubelet)
#
# AWS 와의 대응
#   - cluster identity  ≈ EKS cluster IAM role   (컨트롤 플레인이 LB, 디스크, 서브넷 등을 관리)
#   - kubelet identity  ≈ EKS node IAM role      (노드가 ACR 이미지를 pull)
# Azure 에서는 "Role 에 신뢰 정책을 붙이는" 대신, 리소스(UAMI)를 만들고
# 대상 리소스 scope 에 역할 할당(role assignment)을 추가합니다. 장기 자격 증명(키)은 없습니다.
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "aks_cluster" {
  name                = module.naming.names.id_aks_cluster
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = module.naming.names.id_aks_kubelet
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

# 컨트롤 플레인이 BYO VNet 의 서브넷/NAT Gateway 를 사용할 수 있도록 네트워크 리소스 그룹에 Network Contributor.
# (더 엄격하게 하려면 VNet / 서브넷 scope 로 좁힐 수 있습니다.)
resource "azurerm_role_assignment" "cluster_network" {
  scope                = data.azurerm_resource_group.network.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# BYO kubelet identity 를 쓰려면 컨트롤 플레인 identity 가 kubelet identity 를 노드에 붙일 수 있어야 합니다.
resource "azurerm_role_assignment" "cluster_manages_kubelet" {
  scope                = azurerm_user_assigned_identity.aks_kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# 노드(kubelet)가 ACR 에서 이미지를 pull: ECR 의 ecr:GetAuthorizationToken / BatchGetImage 권한에 해당.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
  principal_type       = "ServicePrincipal"
}

# 실습자(현재 로그인 사용자)가 이미지를 push 할 수 있도록 AcrPush 부여.
# 팀/CI 환경에서는 grant_current_user_roles = false 로 끄고, 그룹/CI 주체에 별도로 역할을 부여하세요.
resource "azurerm_role_assignment" "operator_acr_push" {
  count = var.grant_current_user_roles ? 1 : 0

  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}
```
<!-- /tf:include -->

**`registry.tf`** — ACR + Private Endpoint + 진단 설정

<!-- tf:include path="terraform/04-platform/registry.tf" -->
```hcl title="terraform/04-platform/registry.tf"
# ---------------------------------------------------------------------------
# Azure Container Registry  (Amazon ECR 에 해당)
#   - ECR 은 리전/계정 단위 레지스트리 + 리포지토리, ACR 은 "레지스트리 1개 = 로그인 서버 1개" 입니다.
#   - Private Endpoint / 방화벽 규칙 / 영역 중복은 Premium SKU 에서 제공합니다.
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "this" {
  name                = module.naming.names.acr
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  sku                 = "Premium"

  admin_enabled            = false # 정적 admin 계정 대신 Entra ID + RBAC 사용
  anonymous_pull_enabled   = false
  zone_redundancy_enabled  = true
  retention_policy_in_days = 7 # 태그 없는(untagged) 매니페스트 자동 정리 (ECR 라이프사이클 정책과 유사)

  # 공용 엔드포인트는 "관리자 IP + 신뢰된 Azure 서비스(network_rule_bypass_option 기본값 AzureServices)" 만 허용하고 나머지는 Deny.
  # 노드/파드는 Private Endpoint 로 pull 합니다.
  # (azurerm 5.x 에서는 network_rule_set 이 중첩 속성이라 `= [{ ... }]` 형태로 작성합니다.)
  public_network_access_enabled = true

  network_rule_set = [{
    default_action = "Deny"
    ip_rule = [for cidr in var.allowed_ip_ranges : {
      action   = "Allow"
      ip_range = cidr
    }]
  }]

  tags = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-${module.naming.names.acr}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = data.azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-acr"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.acr.id]
  }

  tags = local.tags
}

# 레지스트리 로그인/이미지 push·pull 이벤트를 Log Analytics 로 전송 (CloudTrail data events 와 유사)
resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
```
<!-- /tf:include -->

**`keyvault.tf`**

<!-- tf:include path="terraform/04-platform/keyvault.tf" -->
```hcl title="terraform/04-platform/keyvault.tf"
# ---------------------------------------------------------------------------
# Azure Key Vault  (AWS KMS + Secrets Manager + ACM 을 한 서비스로 합친 것에 가깝습니다)
#   - 키(Key) / 시크릿(Secret) / 인증서(Certificate) 를 모두 보관
#   - Access policy 대신 Azure RBAC(rbac_authorization_enabled) 사용 → IAM 정책 모델과 동일한 방식
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "this" {
  name                = module.naming.names.key_vault
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = 7

  # 공용 엔드포인트는 "관리자 IP + 신뢰된 Azure 서비스(bypass)" 만 허용하고 나머지는 차단합니다.
  # 파드(CSI Driver)는 Private Endpoint 로 접근합니다. 신뢰된 Azure 서비스까지 막으려면 bypass = "None" 으로 바꾸세요.
  public_network_access_enabled = true

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = local.key_vault_ip_rules
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-${module.naming.names.key_vault}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = data.azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "psc-key-vault"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.key_vault.id]
  }

  tags = local.tags
}

# 시크릿/키 접근 감사 로그 (AuditEvent) → Log Analytics. CloudTrail 의 KMS/SecretsManager 이벤트에 해당.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "audit"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
```
<!-- /tf:include -->

**`observability.tf`** — Log Analytics, Azure Monitor workspace, Managed Grafana

<!-- tf:include path="terraform/04-platform/observability.tf" -->
```hcl title="terraform/04-platform/observability.tf"
# ---------------------------------------------------------------------------
# 관측성 (CloudWatch Logs / Amazon Managed Prometheus / Amazon Managed Grafana 에 해당)
#   - Log Analytics workspace : 로그 저장·KQL 쿼리 (CloudWatch Logs + Logs Insights)
#   - Azure Monitor workspace : Managed Prometheus 메트릭 저장소 (AMP workspace)
#   - Azure Managed Grafana   : 대시보드 (AMG)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = module.naming.names.log_analytics
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name

  sku                          = "PerGB2018"
  retention_in_days            = var.log_retention_days
  daily_quota_gb               = var.log_daily_quota_gb
  local_authentication_enabled = false # 공유 키 대신 Entra ID(관리 ID) 인증만 허용

  tags = local.tags
}

resource "azurerm_monitor_workspace" "this" {
  name                = module.naming.names.monitor_workspace
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

resource "azurerm_dashboard_grafana" "this" {
  count = var.enable_grafana ? 1 : 0

  name                  = module.naming.names.grafana
  location              = azurerm_resource_group.platform.location
  resource_group_name   = azurerm_resource_group.platform.name
  grafana_major_version = "13"

  api_key_enabled               = false
  public_network_access_enabled = true

  identity {
    type = "SystemAssigned"
  }

  # Managed Prometheus 를 Grafana 데이터 소스로 자동 연결합니다.
  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.this.id
  }

  tags = local.tags
}

# Grafana 가 Prometheus 메트릭을 읽을 수 있도록 Monitoring Data Reader 부여
resource "azurerm_role_assignment" "grafana_reads_prometheus" {
  count = var.enable_grafana ? 1 : 0

  scope                = azurerm_monitor_workspace.this.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# 실습자가 Grafana 에 로그인해서 대시보드를 볼 수 있도록 Grafana Admin 부여 (grant_current_user_roles = false 이면 생략)
resource "azurerm_role_assignment" "operator_grafana_admin" {
  count = var.enable_grafana && var.grant_current_user_roles ? 1 : 0

  scope                = azurerm_dashboard_grafana.this[0].id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/outputs.tf" -->
```hcl title="terraform/04-platform/outputs.tf"
output "resource_group_name" {
  description = "플랫폼 공용 서비스 리소스 그룹"
  value       = azurerm_resource_group.platform.name
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID"
  value       = azurerm_log_analytics_workspace.this.id
}

output "monitor_workspace_id" {
  description = "Azure Monitor workspace(Managed Prometheus) ID"
  value       = azurerm_monitor_workspace.this.id
}

output "grafana_endpoint" {
  description = "Managed Grafana URL (enable_grafana=false 이면 null)"
  value       = var.enable_grafana ? azurerm_dashboard_grafana.this[0].endpoint : null
}

output "acr_name" {
  description = "ACR 이름"
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  description = "ACR 로그인 서버 (예: <name>.azurecr.io)"
  value       = azurerm_container_registry.this.login_server
}

output "key_vault_name" {
  description = "Key Vault 이름"
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.this.vault_uri
}

output "aks_cluster_identity" {
  description = "컨트롤 플레인 UAMI 이름 (05-aks 에서 이름 규칙으로 조회)"
  value       = azurerm_user_assigned_identity.aks_cluster.name
}

output "aks_kubelet_identity" {
  description = "kubelet UAMI 이름 (05-aks 에서 이름 규칙으로 조회)"
  value       = azurerm_user_assigned_identity.aks_kubelet.name
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/tests/plan.tftest.hcl" -->
```hcl title="terraform/04-platform/tests/plan.tftest.hcl"
# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/04-platform test
mock_provider "azurerm" {
  source = "../mocks"
}

variables {
  allowed_ip_ranges = ["203.0.113.10/32", "198.51.100.0/24"]
}

run "plan_defaults" {
  command = plan

  assert {
    condition     = azurerm_key_vault.this.network_acls[0].ip_rules == toset(["203.0.113.10", "198.51.100.0/24"])
    error_message = "Key Vault IP 규칙에서 /32 는 단일 IP 로 변환되어야 합니다."
  }

  assert {
    condition     = azurerm_container_registry.this.sku == "Premium"
    error_message = "Private Endpoint 를 쓰려면 ACR 은 Premium 이어야 합니다."
  }
}

run "plan_without_grafana" {
  command = plan

  variables {
    enable_grafana = false
  }

  assert {
    condition     = length(azurerm_dashboard_grafana.this) == 0
    error_message = "enable_grafana=false 이면 Grafana 를 만들지 않아야 합니다."
  }
}

run "plan_without_operator_roles" {
  command = plan

  variables {
    grant_current_user_roles = false
  }

  assert {
    condition     = length(azurerm_role_assignment.operator_acr_push) == 0 && length(azurerm_role_assignment.operator_grafana_admin) == 0
    error_message = "grant_current_user_roles=false 이면 실행 주체에게 ACR/Grafana 역할을 부여하지 않아야 합니다."
  }
}

run "rejects_empty_ip_list" {
  command = plan

  variables {
    allowed_ip_ranges = []
  }

  expect_failures = [var.allowed_ip_ranges]
}
```
<!-- /tf:include -->

## 실습 따라하기

```bash
cd terraform/04-platform
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan        # 약 18개 리소스 (Grafana 포함)
terraform apply tfplan            # 5~10분 (Grafana, ACR 이 오래 걸립니다)
```

> [!NOTE]
> Grafana 가 부담스럽다면 `export TF_VAR_enable_grafana=false` 후 실행하세요. 클러스터 동작에는 영향이 없고, Lab 05 의 Prometheus 수집은 그대로 됩니다.

### 검증

```bash
ACR=$(terraform output -raw acr_name); KV=$(terraform output -raw key_vault_name)

az acr show -n "$ACR" --query "{sku:sku.name, adminUser:adminUserEnabled, publicAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, zoneRedundancy:zoneRedundancy}" -o json

az keyvault show -n "$KV" --query "{rbac:properties.enableRbacAuthorization, purgeProtection:properties.enablePurgeProtection, defaultAction:properties.networkAcls.defaultAction, ipRules:properties.networkAcls.ipRules[].value}" -o json

# Private Endpoint 와 DNS 레코드 (Private DNS Zone 에 A 레코드가 생겼는지)
az network private-endpoint list -g "$(terraform output -raw resource_group_name)" -o table
az network private-dns record-set a list -g "$(az group list --query "[?ends_with(name,'-network')].name | [0]" -o tsv)" \
   -z privatelink.azurecr.io -o table

# 이미지 import 테스트: ECR 에서 이미지를 가져오듯 외부 레지스트리 → ACR 서버 측 복사
az acr import -n "$ACR" --source mcr.microsoft.com/cbl-mariner/busybox:2.0 --image demo/busybox:2.0
az acr repository list -n "$ACR" -o table
```

> [!TIP]
> Grafana 접속: `terraform output grafana_endpoint` 의 URL → Entra ID 로그인. 데이터 소스에 *Managed Prometheus* 가 이미 연결되어 있습니다(메트릭은 Lab 05 이후부터 쌓입니다).

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `MissingSubscriptionRegistration` | 해당 RP 미등록 → [Lab 01 의 3단계](01-prerequisites.md). `Microsoft.Dashboard`, `Microsoft.Monitor` 를 특히 확인. |
| `az acr import` 가 `403`/`denied` | 공용 접근은 `allowed_ip_ranges` 의 IP 만 허용됩니다. 현재 IP 가 바뀌었는지 확인하고 `terraform apply`. |
| `az keyvault secret set` 이 `Forbidden` | Key Vault 방화벽(IP) 또는 데이터 평면 역할(Key Vault Secrets Officer) 부족. 역할 전파에 수 분 걸릴 수 있습니다. |
| Grafana `ZoneRedundancy`/버전 오류 | `grafana_major_version` 은 azurerm 5.9 기준 12 또는 13. 리전 제약이 있으면 `enable_grafana=false`. |
| Key Vault 이름이 이미 존재(soft-deleted) | provider 의 `recover_soft_deleted_key_vaults = true` 가 복구합니다. 이전에 purge protection 으로 삭제했다면 7일간 복구만 가능합니다. |

다음 → [Lab 05. AKS 클러스터](05-aks.md)
