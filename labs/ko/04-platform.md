<!-- lang-switch -->
[English](../04-platform.md) | **한국어**
<!-- /lang-switch -->

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

![누가 무엇을 할 수 있는가: 주체 → 역할 → 범위](diagrams/platform-identities.svg)

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
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }

    key_vault {
      # If a soft-deleted Key Vault with the same name exists, recover it instead of creating a new one.
      recover_soft_deleted_key_vaults = true
      purge_soft_delete_on_destroy    = false
    }

    log_analytics_workspace {
      # Permanently delete on destroy so the same name can be reused after the lab.
      permanently_delete_on_destroy = true
    }
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/variables.tf" -->
```hcl title="terraform/04-platform/variables.tf"
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
    Administrator public IPs (list of CIDRs) to allow through the ACR / Key Vault firewalls.
    Example: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
    Nodes/pods connect through Private Endpoints, so this list is for "people/CI".
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "Specify at least one CIDR in allowed_ip_ranges. Example: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "enable_grafana" {
  description = "Whether to create Azure Managed Grafana (the Standard SKU is billed hourly)."
  type        = bool
  default     = true
}

variable "grant_current_user_roles" {
  description = <<-EOT
    If true, grants lab roles (AcrPush on ACR, Grafana Admin on Grafana) to the "currently signed-in principal"
    that runs terraform. In team/CI environments, set it to false and assign roles to an Entra group (for people)
    or a separate service principal (for CI) instead.
  EOT
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Log Analytics retention period (days)"
  type        = number
  default     = 30
}

variable "log_daily_quota_gb" {
  description = "Log Analytics daily ingestion cap (GB). A safeguard against runaway lab costs. -1 means unlimited."
  type        = number
  default     = 5
}

variable "key_vault_purge_protection_enabled" {
  description = "Key Vault purge protection. true is recommended in production; once enabled, it cannot be disabled."
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

  # Key Vault IP rules do not accept /31 or /32 prefixes, so they are converted to single IPs.
  key_vault_ip_rules = [for cidr in var.allowed_ip_ranges : replace(cidr, "/32", "")]
}

# ---------------------------------------------------------------------------
# Look up the resources created by the 03-network stack by "naming convention".
# Works like AWS `data "aws_vpc"` + tag lookups, and has no remote state dependency.
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
# Platform (shared services) resource group
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
# Two managed identities used by AKS (cluster / kubelet)
#
# Mapping to AWS
#   - cluster identity  ≈ EKS cluster IAM role   (the control plane manages LBs, disks, subnets, etc.)
#   - kubelet identity  ≈ EKS node IAM role      (nodes pull images from ACR)
# Instead of "attaching a trust policy to a Role", Azure has you create a resource (UAMI) and
# add a role assignment at the scope of the target resource. There are no long-lived credentials (keys).
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

# Network Contributor on the network resource group so the control plane can use the subnets/NAT Gateway of the BYO VNet.
# (For stricter access, you can narrow the scope to the VNet / subnet.)
resource "azurerm_role_assignment" "cluster_network" {
  scope                = data.azurerm_resource_group.network.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# To use a BYO kubelet identity, the control plane identity must be able to attach the kubelet identity to the nodes.
resource "azurerm_role_assignment" "cluster_manages_kubelet" {
  scope                = azurerm_user_assigned_identity.aks_kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# Lets the nodes (kubelet) pull images from ACR: equivalent to the ECR permissions ecr:GetAuthorizationToken / BatchGetImage.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
  principal_type       = "ServicePrincipal"
}

# Grant AcrPush so the lab user (the currently signed-in user) can push images.
# In team/CI environments, turn this off with grant_current_user_roles = false and assign roles to
# a group/CI principal separately.
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
# Azure Container Registry  (equivalent to Amazon ECR)
#   - ECR is a per-region/per-account registry plus repositories, while ACR is "one registry = one login server".
#   - Private Endpoint / firewall rules / zone redundancy are available in the Premium SKU.
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "this" {
  name                = module.naming.names.acr
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  sku                 = "Premium"

  admin_enabled            = false # Use Entra ID + RBAC instead of a static admin account
  anonymous_pull_enabled   = false
  zone_redundancy_enabled  = true
  retention_policy_in_days = 7 # Automatically clean up untagged manifests (similar to ECR lifecycle policies)

  # The public endpoint allows only "admin IPs + trusted Azure services (network_rule_bypass_option defaults to
  # AzureServices)" and denies everything else. Nodes/pods pull through the Private Endpoint.
  # (In azurerm 5.x, network_rule_set is a nested attribute, so it is written as `= [{ ... }]`.)
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

# Send registry login and image push/pull events to Log Analytics (similar to CloudTrail data events)
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
# Azure Key Vault  (close to AWS KMS + Secrets Manager + ACM combined into one service)
#   - Stores keys, secrets, and certificates
#   - Uses Azure RBAC (rbac_authorization_enabled) instead of access policies → the same approach as the IAM policy model
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

  # The public endpoint allows only "admin IPs + trusted Azure services (bypass)" and blocks everything else.
  # Pods (CSI Driver) connect through the Private Endpoint. To block trusted Azure services too, change bypass to "None".
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

# Secret/key access audit logs (AuditEvent) → Log Analytics. Equivalent to the KMS/SecretsManager events in CloudTrail.
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
# Observability (equivalent to CloudWatch Logs / Amazon Managed Prometheus / Amazon Managed Grafana)
#   - Log Analytics workspace : log storage and KQL queries (CloudWatch Logs + Logs Insights)
#   - Azure Monitor workspace : Managed Prometheus metric store (AMP workspace)
#   - Azure Managed Grafana   : dashboards (AMG)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = module.naming.names.log_analytics
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name

  sku                          = "PerGB2018"
  retention_in_days            = var.log_retention_days
  daily_quota_gb               = var.log_daily_quota_gb
  local_authentication_enabled = false # Allow only Entra ID (managed identity) authentication instead of shared keys

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

  # Automatically connects Managed Prometheus as a Grafana data source.
  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.this.id
  }

  tags = local.tags
}

# Grant Monitoring Data Reader so Grafana can read Prometheus metrics
resource "azurerm_role_assignment" "grafana_reads_prometheus" {
  count = var.enable_grafana ? 1 : 0

  scope                = azurerm_monitor_workspace.this.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Grant Grafana Admin so the lab user can sign in to Grafana and view dashboards (skipped if grant_current_user_roles = false)
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
  description = "Resource group for the platform shared services"
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
  description = "Managed Grafana URL (null if enable_grafana=false)"
  value       = var.enable_grafana ? azurerm_dashboard_grafana.this[0].endpoint : null
}

output "acr_name" {
  description = "ACR name"
  value       = azurerm_container_registry.this.name
}

output "acr_login_server" {
  description = "ACR login server (e.g., <name>.azurecr.io)"
  value       = azurerm_container_registry.this.login_server
}

output "key_vault_name" {
  description = "Key Vault name"
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.this.vault_uri
}

output "aks_cluster_identity" {
  description = "Control plane UAMI name (looked up by naming convention in 05-aks)"
  value       = azurerm_user_assigned_identity.aks_cluster.name
}

output "aks_kubelet_identity" {
  description = "kubelet UAMI name (looked up by naming convention in 05-aks)"
  value       = azurerm_user_assigned_identity.aks_kubelet.name
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/04-platform/tests/plan.tftest.hcl" -->
```hcl title="terraform/04-platform/tests/plan.tftest.hcl"
# Verify only the plan logic, without Azure: terraform -chdir=terraform/04-platform test
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
    error_message = "/32 in the Key Vault IP rules must be converted to a single IP."
  }

  assert {
    condition     = azurerm_container_registry.this.sku == "Premium"
    error_message = "ACR must be Premium to use a Private Endpoint."
  }
}

run "plan_without_grafana" {
  command = plan

  variables {
    enable_grafana = false
  }

  assert {
    condition     = length(azurerm_dashboard_grafana.this) == 0
    error_message = "If enable_grafana=false, Grafana must not be created."
  }
}

run "plan_without_operator_roles" {
  command = plan

  variables {
    grant_current_user_roles = false
  }

  assert {
    condition     = length(azurerm_role_assignment.operator_acr_push) == 0 && length(azurerm_role_assignment.operator_grafana_admin) == 0
    error_message = "If grant_current_user_roles=false, the ACR/Grafana roles must not be granted to the principal running Terraform."
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

### 자동 검증 스크립트

ACR · Key Vault 의 방화벽/Private Endpoint, Log Analytics, Prometheus workspace, AKS 용 UAMI 와 **역할 할당**(kubelet → AcrPull 등)을 확인합니다 (읽기 전용).

```bash
cd ../..                          # 저장소 루트에서 실행
scripts/verify.sh 04-platform
```

<!-- tf:include path="scripts/verify/04-platform.sh" -->
```bash title="scripts/verify/04-platform.sh"
#!/usr/bin/env bash
# Lab 04 verification: checks ACR · Key Vault · Log Analytics · Prometheus/Grafana · the identities for AKS
# and their role assignments (read-only).
#   AWS comparison: ECR · KMS/Secrets Manager · CloudWatch Logs · Managed Prometheus/Grafana · IAM Role + policies
# Usage: scripts/verify.sh 04-platform
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Is there at least one Private Endpoint connection, and are all of them Approved?
# (the JSON nesting differs by az version, so both shapes are accepted)
PE_APPROVED='[.[]? | (.privateLinkServiceConnectionState // .properties.privateLinkServiceConnectionState).status] | length >= 1 and all(.[]; . == "Approved")'

verify_stack() {
  local rg net_rg acr kv law_id law_name amw_id grafana acr_json kv_json law amw
  local id_cluster id_kubelet cluster_pid kubelet_pid net_rg_id
  rg="$(tf_out 04-platform resource_group_name)"
  net_rg="$(tf_out 03-network resource_group_name)"
  acr="$(tf_out 04-platform acr_name)"
  kv="$(tf_out 04-platform key_vault_name)"
  law_id="$(tf_out 04-platform log_analytics_workspace_id)"
  amw_id="$(tf_out 04-platform monitor_workspace_id)"
  grafana="$(tf_out 04-platform grafana_endpoint)"
  id_cluster="$(tf_out 04-platform aks_cluster_identity)"
  id_kubelet="$(tf_out 04-platform aks_kubelet_identity)"

  section "04-platform · platform services (${rg:-?})"
  if [ -z "$rg" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 04-platform?"
    return
  fi

  # --- ACR (ECR) ---
  acr_json="$(azj acr show -g "$rg" -n "$acr")"
  expect_eq "ACR SKU (Private Endpoint requires Premium)" "$(jv "$acr_json" .sku.name)" "Premium"
  expect_eq "ACR admin user enabled" "$(jv "$acr_json" .adminUserEnabled)" "false"
  expect_eq "ACR anonymous pull allowed" "$(jv "$acr_json" .anonymousPullEnabled)" "false"
  expect_eq "ACR default action for public access (firewall)" "$(jv "$acr_json" .networkRuleSet.defaultAction)" "Deny"
  jq_ok "ACR Private Endpoint approved" "$acr_json" ".privateEndpointConnections | $PE_APPROVED"

  # --- Key Vault (KMS + Secrets Manager) ---
  kv_json="$(azj keyvault show -n "$kv")"
  expect_eq "Key Vault permission model = Azure RBAC" "$(jv "$kv_json" .properties.enableRbacAuthorization)" "true"
  expect_eq "Key Vault default action for public access (firewall)" "$(jv "$kv_json" .properties.networkAcls.defaultAction)" "Deny"
  jq_warn "Key Vault purge protection on (recommended for production)" "$kv_json" '.properties.enablePurgeProtection == true'
  jq_ok "Key Vault Private Endpoint approved" "$kv_json" ".properties.privateEndpointConnections | $PE_APPROVED"

  # --- Observability ---
  law_name="${law_id##*/}"
  law="$(azj monitor log-analytics workspace show -g "$rg" -n "$law_name")"
  expect_eq "Log Analytics local (shared key) auth disabled" "$(jv "$law" .features.disableLocalAuth)" "true"
  expect_set "Log Analytics retention (days)" "$(jv "$law" .retentionInDays)"
  amw="$(azj resource show --ids "$amw_id")"
  expect_eq "Azure Monitor workspace (Managed Prometheus) state" "$(jv "$amw" .properties.provisioningState)" "Succeeded"
  if [ -n "$grafana" ]; then
    pass "Managed Grafana: $grafana"
  else
    skip "No Managed Grafana (enable_grafana = false)"
  fi

  # --- Managed Identities for AKS and their role assignments (equivalent to an IAM Role + attached policies) ---
  cluster_pid="$(jv "$(azj identity show -g "$rg" -n "$id_cluster")" .principalId)"
  kubelet_pid="$(jv "$(azj identity show -g "$rg" -n "$id_kubelet")" .principalId)"
  expect_set "Control plane UAMI ($id_cluster)" "$cluster_pid"
  expect_set "kubelet UAMI ($id_kubelet)" "$kubelet_pid"
  net_rg_id="$(az group show -n "$net_rg" --query id -o tsv 2>/dev/null)"
  if [ -n "$kubelet_pid" ] && [ -n "$cluster_pid" ]; then
    has_role "kubelet → AcrPull (ACR)" "$kubelet_pid" "AcrPull" "$(jv "$acr_json" .id)"
    has_role "Control plane → Network Contributor (network RG)" "$cluster_pid" "Network Contributor" "$net_rg_id"
  fi
}

# You can also run it directly (scripts/verify/04-platform.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `MissingSubscriptionRegistration` | 해당 RP 미등록 → [Lab 01 의 3단계](01-prerequisites.md). `Microsoft.Dashboard`, `Microsoft.Monitor` 를 특히 확인. |
| `az acr import` 가 `403`/`denied` | 공용 접근은 `allowed_ip_ranges` 의 IP 만 허용됩니다. 현재 IP 가 바뀌었는지 확인하고 `terraform apply`. |
| `az keyvault secret set` 이 `Forbidden` | Key Vault 방화벽(IP) 또는 데이터 평면 역할(Key Vault Secrets Officer) 부족. 역할 전파에 수 분 걸릴 수 있습니다. |
| Grafana `ZoneRedundancy`/버전 오류 | `grafana_major_version` 은 azurerm 5.9 기준 12 또는 13. 리전 제약이 있으면 `enable_grafana=false`. |
| Key Vault 이름이 이미 존재(soft-deleted) | provider 의 `recover_soft_deleted_key_vaults = true` 가 복구합니다. 이전에 purge protection 으로 삭제했다면 7일간 복구만 가능합니다. |

다음 → [Lab 05. AKS 클러스터](05-aks.md)
