# 부록. 트러블슈팅 · 프로덕션 체크리스트 · 참고 자료 · 테스트 코드

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 참고용 | 없음 | `terraform/mocks`, `scripts/`, `tools/validate-all.sh` | 없음 |

## A. 이 가이드를 검증한 방법과 한계

| 검증 | 내용 | 결과 |
|---|---|---|
| `terraform fmt -check` | 모든 스택/모듈 | 통과 |
| `terraform validate` | azurerm 5.9.0 · azapi 2.13.0 · kubernetes 3.3.0 · random 3.9.1 · time 0.14.2 실제 스키마 기준 | 통과 |
| `terraform test` (mock provider) | 모든 스택의 plan 로직 + 변수 검증(`naming` 모듈 포함 총 <!-- count:test-runs -->28<!-- /count -->개 run) | 통과 |
| AzAPI 본문 검증 | `Microsoft.ContainerService/managedClusters@2026-05-01` 의 속성명을 OpenAPI 스펙과 azapi 내장 스키마로 확인 | 통과 |
| 내장 정책 정의 ID | `az policy definition show` 로 8개 ID 확인 | 확인 |
| VM 크기/영역 | `Standard_D4ds_v5` 가 koreacentral 영역 1·2·3 에서 사용 가능한지 확인 | 확인 |
| 셸 스크립트 정적 검사 | `scripts/` 전체를 `bash -n` 과 ShellCheck 로 검사, macOS 기본 bash 3.2 로도 실행 | 통과 |
| `scripts/preflight.sh` | 실제 구독에서 **읽기 전용**으로 실행해 도구 · RP · 쿼터 · VM 크기 · 역할 판정 결과를 확인 | 확인 |
| `scripts/verify.sh` | `az` 가 돌려주는 JSON 의 속성 경로를 같은 종류의 실제 리소스(Storage · VNet · NAT Gateway · ACR · Key Vault · Log Analytics · UAMI · AKS)로 확인. kubectl 단계는 모의 응답으로 로직 확인 | 부분 확인 |
| `scripts/cleanup.sh` | `--dry-run` 과 모의 terraform 으로 삭제 순서 · 재실행 · 실패 시 중단 · 확인 입력/구독 불일치 같은 안전장치를 확인. **실제 삭제는 실행하지 않음** | 확인 |

> [!WARNING]
> **실제 Azure 구독에 `apply` 한 결과는 아닙니다.** 리전별 용량(VM/NAT StandardV2), 쿼터, 조직 정책(Management group 의 Azure Policy), preview 기능 상태 등은 환경마다 다를 수 있습니다. 처음에는 `terraform plan` 을 꼼꼼히 읽고, 문제가 있으면 아래 *B. 트러블슈팅 모음* 과 각 Lab 의 *자주 만나는 문제* 를 확인하세요. 같은 이유로 `scripts/verify.sh` 와 `scripts/cleanup.sh` 도 이 가이드의 스택을 실제로 배포한 환경에서는 실행해 보지 못했으므로, 처음에는 `cleanup.sh --dry-run` 으로 계획을 먼저 확인하세요.

## B. 트러블슈팅 모음

| 증상 | 원인 / 해결 |
|---|---|
| `Error: ... subscription_id is a required provider property` | `ARM_SUBSCRIPTION_ID` 환경 변수 설정 ([Lab 01](01-prerequisites.md)). |
| `MissingSubscriptionRegistration` / `ResourceProviderNotRegistered` | RP 등록 (azurerm 5.x 는 자동 등록하지 않음). `az provider register --namespace Microsoft.XXX`. |
| `AuthorizationFailed` | 현재 사용자 권한(Contributor + User Access Administrator 또는 Owner) 부족, 또는 방금 만든 역할 할당 전파 대기(최대 5분). |
| `Error acquiring the state lock` | 다른 실행이 진행 중이거나 비정상 종료. 확실할 때만 `terraform force-unlock <LOCK_ID>`. |
| `Error: Unsupported argument` / `Missing required argument` (azurerm) | 4.x 코드와 5.x 스키마 차이. `terraform validate` 로 위치를 확인하고 [5.0 업그레이드 가이드](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/5.0-upgrade-guide) 참조. |
| `Provider produced inconsistent result after apply` (kubernetes_manifest) | CRD 기본값/서버 정규화 차이. `terraform apply` 재시도 또는 `computed_fields` 사용. |
| `StorageAccountAlreadyTaken` / `VaultAlreadyExists` / ACR 이름 충돌 | 전역 고유 이름 충돌. `TF_VAR_workload` 변경 또는 soft-deleted Key Vault 복구/purge. |
| `terraform destroy` 가 `ScopeLocked` | 리소스 잠금 해제 ([Lab 08](08-governance.md), [Lab 11](11-cleanup.md)). |
| `kubectl: Unable to connect ... i/o timeout` | 내 공인 IP 변경 → `TF_VAR_allowed_ip_ranges` 갱신 후 05-aks `apply` (API 서버 authorized IP). |
| `kubelogin` 오류 / `Unauthorized` | `az login` 재실행, `kubelogin convert-kubeconfig -l azurecli`, Azure RBAC 역할 전파 대기. |
| `terraform plan` 이 매번 `node_count` 변경을 요구 | 오토스케일러와 충돌. 코드에 `node_count` 를 쓰지 말고 `min_count`/`max_count` 만 사용 ([Lab 09](09-operations.md)). |

## C. 프로덕션으로 가기 전 체크리스트

이 가이드는 **학습/PoC 를 위한 비용 균형형 구성**입니다. 운영 환경에서는 Microsoft [AKS 베이스라인 아키텍처](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks)를 기준으로 아래를 추가하세요.

| 영역 | 이 가이드 | 프로덕션 권장 |
|---|---|---|
| 네트워크 토폴로지 | 단일 VNet + NAT Gateway | **허브-스포크**: 허브에 Azure Firewall(egress 통제, UDR)·Bastion·VPN/ExpressRoute, 스포크에 AKS |
| API 서버 | 공용 + authorized IP | **완전 프라이빗**(`enable_private_cluster`) + Bastion/점프 호스트/자체 호스팅 러너 |
| 인그레스 | Gateway API 공용 LB | **Application Gateway(WAF v2) 또는 Front Door** → 내부 Gateway, TLS 종단(Key Vault 인증서) |
| 레지스트리/KV | Private Endpoint + 관리자 IP 허용 | 공용 접근 **완전 차단**, CI 는 VNet 내부/관리형 러너 |
| ID | 사용자에게 직접 역할 | **Entra 그룹 + PIM(Just-in-time)**, 조건부 액세스, 접근 검토 |
| 거버넌스 | RG 범위 정책 (Audit) | 관리 그룹 범위 정책/이니셔티브 + `Deny`, 태그 상속·필수 태그 정책 |
| 보안 | 선택적 Defender | Defender for Containers + (Sentinel 커넥터), 이미지 서명/스캔 파이프라인 |
| 복원력 | 단일 리전(영역 3곳) | **Azure Backup for AKS**, 멀티 리전 + Front Door/Traffic Manager, Fleet Manager |
| 배포 | `terraform apply` + kubectl | **GitOps(Flux 확장)** 로 클러스터 부트스트랩/앱 배포, 파이프라인에서 OIDC 로그인 |
| 모듈화 | 학습용 직접 정의 | 사내 모듈 또는 **Azure Verified Modules(AVM)** 로 표준화 |
| 관측성 | 기본 대시보드 | Prometheus 알림 규칙(`azurerm_monitor_alert_prometheus_rule_group`) + Action Group, SLO 대시보드 |

## D. 참고 자료

| 주제 | 링크 |
|---|---|
| AWS ↔ Azure 비교 | [Azure for AWS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/), [AKS for Amazon EKS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/eks-to-aks/) |
| 아키텍처 | [AKS 베이스라인](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks), [AKS Well-Architected 가이드](https://learn.microsoft.com/azure/well-architected/service-guides/azure-kubernetes-service) |
| AKS Automatic / NAP | [AKS Automatic 소개](https://learn.microsoft.com/azure/aks/intro-aks-automatic), [Node auto-provisioning](https://learn.microsoft.com/azure/aks/node-auto-provisioning) |
| Gateway API | [App Routing Gateway API](https://learn.microsoft.com/azure/aks/app-routing-gateway-api), [NGINX → Gateway API 마이그레이션](https://learn.microsoft.com/azure/aks/app-routing-nginx-to-gateway-api-migration), [Managed Gateway API CRD](https://learn.microsoft.com/azure/aks/managed-gateway-api) |
| 지원 버전/일정 | [Supported Kubernetes versions](https://learn.microsoft.com/azure/aks/supported-kubernetes-versions), [AKS 릴리스 노트](https://github.com/Azure/AKS/releases) |
| Terraform | [azurerm 5.0 업그레이드 가이드](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/5.0-upgrade-guide), [`azurerm_kubernetes_cluster`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster), [`azurerm_kubernetes_automatic_cluster`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_automatic_cluster), [AzAPI](https://registry.terraform.io/providers/Azure/azapi/latest/docs), [AVM](https://azure.github.io/Azure-Verified-Modules/) |
| Microsoft 공식 Terraform 샘플 | [Azure/terraform quickstart](https://github.com/Azure/terraform/tree/master/quickstart): `101-aks-application-routing-gateway-api`, `101-aks-automatic-custom-network`, `101-aks-network-isolated`, `101-aks-use-azure-policy`, `101-aks-defender-containers`, `301-aks-enterprise` |
| Prometheus 템플릿 | [Azure/prometheus-collector — AddonTerraformTemplate](https://github.com/Azure/prometheus-collector/tree/main/AddonTerraformTemplate) |

## E. Terraform 파일 전체 목록 (어느 Lab 에 있나)

| 스택 / 모듈 | 파일 | 실린 곳 |
|---|---|---|
| `modules/naming` | `variables.tf` `main.tf` `outputs.tf` `versions.tf` `tests/naming.tftest.hcl` | [Lab 02](02-bootstrap.md) |
| `02-bootstrap` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 02](02-bootstrap.md) |
| `03-network` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 03](03-network.md) |
| `04-platform` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `identity.tf` `registry.tf` `keyvault.tf` `observability.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 04](04-platform.md) |
| `05-aks` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `cluster.tf` `monitoring.tf` `prometheus-rules.tf` `gateway-api.tf` `access.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 05](05-aks.md) |
| `06-workload` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `identity.tf` `kubernetes.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 06](06-workload-identity.md) |
| `07-ingress` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `app.tf` `gateway.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 07](07-ingress.md) |
| `08-governance` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `policy.tf` `security.tf` `budget.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 08](08-governance.md) |
| `10-aks-automatic` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `cluster.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 10](10-aks-automatic.md) |
| `mocks` | `azurerm.tfmock.hcl` | 아래 F |

> [!NOTE]
> 모든 스택은 같은 파일 구성(`versions.tf` → `providers.tf` → `variables.tf` → `main.tf` → 주제별 파일 → `outputs.tf`)을 따릅니다. 파일을 한 곳에 모아 보고 싶다면 이 HTML 의 검색창에 파일 이름(예: `cluster.tf`)을 입력하세요.

## F. 테스트/도구 코드 전체

각 스택의 `tests/plan.tftest.hcl` 은 해당 Lab 의 코드 섹션에 있습니다. 공통 mock 값과 전체 검증 스크립트는 아래와 같습니다.

**`terraform/mocks/azurerm.tfmock.hcl`** — 모든 스택의 mock 테스트가 공유하는 azurerm 모의 값

<!-- tf:include path="terraform/mocks/azurerm.tfmock.hcl" -->
```hcl title="terraform/mocks/azurerm.tfmock.hcl"
# terraform test 용 azurerm provider 모의(mock) 값.
#
# Azure 구독/로그인 없이 `terraform test` 로 plan 단계의 로직(변수 검증, count/for_each, 조건식, merge 등)을
# 검증하기 위해 "올바른 형식의 ID/UUID" 를 돌려주도록 정의합니다.
# 각 스택의 tests/plan.tftest.hcl 에서 `mock_provider "azurerm" { source = "../mocks" }` 로 불러 씁니다.

mock_data "azurerm_client_config" {
  defaults = {
    client_id       = "00000000-0000-0000-0000-0000000000c1"
    tenant_id       = "00000000-0000-0000-0000-0000000000a1"
    subscription_id = "00000000-0000-0000-0000-0000000000b1"
    object_id       = "00000000-0000-0000-0000-0000000000d1"
  }
}

mock_data "azurerm_resource_group" {
  defaults = {
    id       = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock"
    location = "koreacentral"
  }
}

mock_data "azurerm_virtual_network" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock"
  }
}

mock_data "azurerm_subnet" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mock"
  }
}

mock_data "azurerm_private_dns_zone" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/privateDnsZones/privatelink.mock.net"
  }
}

mock_data "azurerm_user_assigned_identity" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mock"
    client_id    = "00000000-0000-0000-0000-0000000000e1"
    principal_id = "00000000-0000-0000-0000-0000000000e2"
    tenant_id    = "00000000-0000-0000-0000-0000000000a1"
  }
}

mock_data "azurerm_log_analytics_workspace" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/log-mock"
  }
}

mock_data "azurerm_monitor_workspace" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Monitor/accounts/amw-mock"
  }
}

mock_data "azurerm_container_registry" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ContainerRegistry/registries/acrmock"
    login_server = "acrmock.azurecr.io"
  }
}

mock_data "azurerm_key_vault" {
  defaults = {
    id        = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.KeyVault/vaults/kv-mock"
    vault_uri = "https://kv-mock.vault.azure.net/"
  }
}

mock_data "azurerm_kubernetes_cluster" {
  defaults = {
    id              = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ContainerService/managedClusters/aks-mock"
    oidc_issuer_url = "https://koreacentral.oic.prod-aks.azure.com/00000000-0000-0000-0000-0000000000a1/11111111-1111-1111-1111-111111111111/"
    kube_config = [{
      host                   = "https://aks-example.hcp.koreacentral.azmk8s.io:443"
      cluster_ca_certificate = "Y2E="
      client_certificate     = ""
      client_key             = ""
      username               = "clusterUser"
      password               = ""
    }]
  }
}

mock_data "azurerm_kubernetes_service_versions" {
  defaults = {
    versions       = ["1.35.8", "1.36.3", "1.36.4"]
    latest_version = "1.36.4"
  }
}

mock_resource "azurerm_resource_group" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock"
  }
}

mock_resource "azurerm_virtual_network" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock"
  }
}

mock_resource "azurerm_subnet" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mock"
  }
}

mock_resource "azurerm_network_security_group" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/networkSecurityGroups/nsg-mock"
  }
}

mock_resource "azurerm_public_ip" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/publicIPAddresses/pip-mock"
  }
}

mock_resource "azurerm_nat_gateway" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/natGateways/ng-mock"
  }
}

mock_resource "azurerm_private_dns_zone" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/privateDnsZones/privatelink.mock.net"
  }
}

mock_resource "azurerm_user_assigned_identity" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mock"
    client_id    = "00000000-0000-0000-0000-0000000000e1"
    principal_id = "00000000-0000-0000-0000-0000000000e2"
    tenant_id    = "00000000-0000-0000-0000-0000000000a1"
  }
}

mock_resource "azurerm_container_registry" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ContainerRegistry/registries/acrmock"
    login_server = "acrmock.azurecr.io"
  }
}

mock_resource "azurerm_key_vault" {
  defaults = {
    id        = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.KeyVault/vaults/kv-mock"
    vault_uri = "https://kv-mock.vault.azure.net/"
  }
}

mock_resource "azurerm_log_analytics_workspace" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/log-mock"
  }
}

mock_resource "azurerm_monitor_workspace" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Monitor/accounts/amw-mock"
  }
}

mock_resource "azurerm_dashboard_grafana" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Dashboard/grafana/amg-mock"
    identity = [{
      type         = "SystemAssigned"
      principal_id = "00000000-0000-0000-0000-0000000000f1"
      tenant_id    = "00000000-0000-0000-0000-0000000000a1"
      identity_ids = []
    }]
  }
}

mock_resource "azurerm_kubernetes_cluster" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ContainerService/managedClusters/aks-mock"
  }
}

mock_resource "azurerm_kubernetes_automatic_cluster" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ContainerService/managedClusters/aksa-mock"
  }
}

mock_resource "azurerm_monitor_data_collection_endpoint" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Insights/dataCollectionEndpoints/dce-mock"
  }
}

mock_resource "azurerm_monitor_data_collection_rule" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Insights/dataCollectionRules/dcr-mock"
  }
}

mock_resource "azurerm_storage_account" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Storage/storageAccounts/stmock"
  }
}

mock_resource "azurerm_storage_container" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Storage/storageAccounts/stmock/blobServices/default/containers/tfstate"
  }
}
```
<!-- /tf:include -->

**`tools/validate-all.sh`** — 구독 없이 전체 스택 검증

<!-- tf:include path="tools/validate-all.sh" -->
```bash title="tools/validate-all.sh"
#!/usr/bin/env bash
# 모든 Terraform 스택을 Azure 자격 증명/구독 없이 정적 검증합니다.
#   fmt -check  →  init -backend=false  →  validate  →  terraform test (mock provider)
#   (modules/naming 은 provider 가 없으므로 terraform test 만 실행)
# 인자 없이 전체를 실행할 때는 scripts/ 의 셸 스크립트도 검사합니다 (bash -n, ShellCheck 가 있으면 함께).
#
# 사용법:
#   tools/validate-all.sh              # 전체 스택 + 셸 스크립트
#   tools/validate-all.sh 05-aks       # 특정 스택만
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}/terraform"

export CHECKPOINT_DISABLE=1
export TF_IN_AUTOMATION=1

if [ "$#" -gt 0 ]; then
  stacks=("$@")
else
  stacks=()
  for d in [0-9][0-9]-*/; do
    stacks+=("${d%/}")
  done
fi

terraform version | head -1

echo
echo "== modules/naming (fmt, validate, test)"
terraform -chdir=modules/naming fmt -check -diff
terraform -chdir=modules/naming init -backend=false -input=false -no-color >/dev/null
terraform -chdir=modules/naming validate -no-color
terraform -chdir=modules/naming test -no-color

for stack in "${stacks[@]}"; do
  echo
  echo "== ${stack}"
  terraform -chdir="${stack}" fmt -check -diff
  terraform -chdir="${stack}" init -backend=false -input=false -no-color >/dev/null
  terraform -chdir="${stack}" validate -no-color
  # Azure 없이 mock provider 로 plan 로직(변수 검증, count/for_each, 조건식)을 검증합니다.
  terraform -chdir="${stack}" test -no-color
done

if [ "$#" -eq 0 ]; then
  echo
  echo "== scripts (bash -n, shellcheck)"
  scripts=("${ROOT}"/scripts/*.sh "${ROOT}"/scripts/lib/*.sh "${ROOT}"/scripts/verify/*.sh)
  for f in "${scripts[@]}"; do bash -n "$f"; done
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${scripts[@]}"
    echo "OK (${#scripts[@]}개 스크립트)"
  else
    echo "shellcheck 가 없어 문법 검사(bash -n)만 실행했습니다 (brew install shellcheck)."
  fi
fi

echo
echo "All checks passed."
```
<!-- /tf:include -->

**`terraform/.gitignore`**

<!-- tf:include path="terraform/.gitignore" -->
```text title="terraform/.gitignore"
# Terraform
.terraform/
*.tfstate
*.tfstate.*
crash.log
*.tfplan
tfplan
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# 환경별 값 (Lab 02 에서 생성 / Lab 01 에서 저장)
backend.hcl
env.sh
*.auto.tfvars
terraform.tfvars

# .terraform.lock.hcl 은 커밋하는 것을 권장합니다 (provider 버전/체크섬 고정).
# 처음에는 terraform init 이 만든 파일을 확인한 뒤 `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=windows_amd64` 로 다른 OS 체크섬도 추가하세요.
```
<!-- /tf:include -->

## G. 검증 · 정리 스크립트

실습 중 손으로 치던 확인/삭제 명령을 스크립트로 묶었습니다. 모두 저장소 루트의 `scripts/` 에 있으며 macOS · Linux · WSL · Azure Cloud Shell(bash)에서 동작합니다(필요: `terraform`, `az`, `jq`, 그리고 05 이후는 `kubectl`, `kubelogin`).

| 스크립트 | 언제 | 하는 일 | 소스가 실린 곳 |
|---|---|---|---|
| `scripts/preflight.sh` | Lab 01, 실습 시작 전 | 도구 · 로그인 · 환경 변수 · Resource Provider · vCPU 쿼터 · VM 크기 · 권한 점검 (읽기 전용) | [Lab 01](01-prerequisites.md) |
| `scripts/verify.sh [스택…]` | 각 스택을 `apply` 한 직후 | `terraform output` 으로 이름을 찾아 `az`/`kubectl` 로 결과 검증, `✓ ✗ ! -` 요약과 종료 코드 (읽기 전용) | 이 부록 |
| `scripts/verify/02…10.sh` | 위 스크립트가 호출 (직접 실행도 가능) | 스택별 검증 항목 | [02](02-bootstrap.md) [03](03-network.md) [04](04-platform.md) [05](05-aks.md) [06](06-workload-identity.md) [07](07-ingress.md) [08](08-governance.md) [10](10-aks-automatic.md) |
| `scripts/cleanup.sh` | Lab 11, 실습을 마친 뒤 | 생성의 역순 `destroy`, 잠금 해제, 재실행 안전, 남은 리소스 점검 (`--dry-run` 지원) | [Lab 11](11-cleanup.md) |
| `scripts/lib/common.sh` | 위 스크립트들이 `source` | 결과 출력(`pass`/`fail`/`warn`), 값 비교(`expect_*`), JSON 헬퍼(`jq`), `terraform output`/`az`/`kubectl` 래퍼 | 이 부록 |
| `tools/validate-all.sh` | 코드를 고친 뒤 | `fmt` · `validate` · `terraform test` (구독 불필요) + 스크립트 문법 검사 | 위 F |

```bash
scripts/verify.sh                    # apply 한 모든 스택 검증 (안 한 스택은 건너뜀)
scripts/verify.sh 05-aks 07-ingress  # 특정 스택만
scripts/cleanup.sh --dry-run         # 삭제 계획만 보기
```

> [!TIP]
> 검증 스크립트는 **읽기 전용**입니다(파드 안에서 `printenv`/`test -s` 를 실행하는 것 외에는 아무것도 바꾸지 않습니다). `kubectl` 은 임시 kubeconfig 를 써서 `~/.kube/config` 를 수정하지 않습니다. 변수로 고를 수 있는 설정(`sku_tier`, `enable_private_cluster`, `enable_gateway_api`, `nat_gateway_sku` 등)을 기본값과 다르게 썼다면 실패(✗) 대신 값을 보여 주거나 경고(!)·건너뜀(-)으로 표시합니다. 새 스택용 검증을 추가하려면 `scripts/verify/NN-이름.sh` 에 `verify_stack` 함수를 만들고 `verify.sh` 의 `ALL_STACKS` 에 이름을 더하세요.

**`scripts/lib/common.sh`** — 모든 스크립트의 공통 함수

<!-- tf:include path="scripts/lib/common.sh" -->
```bash title="scripts/lib/common.sh"
#!/usr/bin/env bash
# 검증·정리 스크립트가 함께 쓰는 공통 함수입니다. 직접 실행하지 않고 source 해서 씁니다.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"      # scripts/verify/*.sh 에서
#
# 들어 있는 것: 결과 출력(pass/fail/warn), 값 비교(expect_*), JSON 헬퍼(jq), terraform output / az / kubectl 래퍼.
# macOS 기본 bash(3.2)에서도 동작하도록 연관 배열 같은 최신 문법은 쓰지 않았습니다.
# shellcheck shell=bash

# 여러 번 source 해도 한 번만 로드합니다.
[ -n "${_AKS_LAB_COMMON_LOADED:-}" ] && return 0
_AKS_LAB_COMMON_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${ROOT}/terraform"

# --- 결과 출력 ---------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_DIM=''; C_OFF=''
fi

PASS=0; FAIL=0; WARN=0; SKIP=0

section() { printf '\n%s== %s%s\n' "$C_BLD" "$*" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$*"; }
warn() { WARN=$((WARN + 1)); printf '  %s!%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  %s-%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
info() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# 마지막에 한 번 호출합니다. 실패가 하나라도 있으면 종료 코드 1.
summary() {
  printf '\n%s요약%s  통과 %s%d%s · 실패 %s%d%s · 경고 %d · 건너뜀 %d\n' \
    "$C_BLD" "$C_OFF" "$C_GRN" "$PASS" "$C_OFF" "$C_RED" "$FAIL" "$C_OFF" "$WARN" "$SKIP"
  [ "$FAIL" -eq 0 ]
}

# --- 값 비교 -----------------------------------------------------------------
expect_eq() { # 설명 실제값 기대값
  if [ "$2" = "$3" ]; then pass "$1 = $3"; else fail "$1: 기대 '$3' / 실제 '${2:-(없음)}'"; fi
}

expect_set() { # 설명 값  (비어 있거나 null 이면 실패)
  if [ -n "$2" ] && [ "$2" != "null" ]; then pass "$1: $2"; else fail "$1: 값이 없습니다"; fi
}

expect_ge() { # 설명 실제값 최소값
  if [ "${2:-0}" -ge "$3" ] 2>/dev/null; then pass "$1: $2 (최소 $3)"; else fail "$1: 최소 $3 필요 / 실제 '${2:-(없음)}'"; fi
}

jq_ok() { # 설명 JSON jq조건  → 조건이 참이면 통과
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then pass "$1"; else fail "$1"; fi
}

jq_warn() { # 설명 JSON jq조건  → 조건이 거짓이면 경고 (필수는 아니지만 권장인 항목)
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then pass "$1"; else warn "$1"; fi
}

# --- JSON / 외부 명령 래퍼 -----------------------------------------------------
# jv JSON 'jq필터' : 값을 문자열로 꺼냅니다 (null 은 빈 문자열, 입력이 비어 있어도 오류 없음)
jv() {
  jq -r "($2) | if . == null then \"\" else tostring end" <<<"$1" 2>/dev/null
}

# azj <az 인자...> : az 를 JSON 으로 실행합니다. 실패하면 빈 문자열 (리소스가 없을 때도 스크립트가 멈추지 않게).
azj() { az "$@" -o json 2>/dev/null || true; }

# kj <kubectl 인자...> : kubectl 결과를 JSON 으로 가져옵니다. API 서버가 응답하지 않아도 20초 뒤 포기합니다.
kj() { kubectl --request-timeout=20s "$@" -o json 2>/dev/null || true; }

# tf_out 스택 출력이름 : terraform output -raw (값이 없거나 apply 전이면 빈 문자열)
tf_out() { terraform -chdir="${TF_DIR}/$1" output -raw "$2" 2>/dev/null || true; }

# tf_applied 스택 : 출력이 하나라도 있으면(= init 과 apply 를 마쳤으면) 0
tf_applied() {
  local out
  out="$(terraform -chdir="${TF_DIR}/$1" output -json 2>/dev/null)" || return 1
  [ -n "$out" ] && [ "$out" != "{}" ]
}

# has_role 설명 principalId 역할이름 scope접두사
#   이 주체에게 해당 범위(scope) 아래로 역할이 할당되어 있으면 통과합니다 (대소문자 무시).
#   AWS 비교: "IAM Role 에 정책이 붙어 있는가" → Azure 는 "주체 + 역할 + 범위" 세 요소의 할당입니다.
has_role() {
  local roles
  roles="$(azj role assignment list --assignee "$2" --all)"
  if jq -e --arg role "$3" --arg scope "$4" \
    'any(.[]; .roleDefinitionName == $role and ((.scope | ascii_downcase) | startswith($scope | ascii_downcase)))' \
    >/dev/null 2>&1 <<<"$roles"; then
    pass "$1"
  else
    fail "$1"
  fi
}

# require_cmd 명령... : 모두 있으면 0, 없으면 안내를 출력하고 1
require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "필요한 명령이 없습니다: $c" >&2; missing=1; }
  done
  return "$missing"
}

# version_ge 현재 최소 : 현재 버전 >= 최소 버전 이면 0 (예: version_ge 1.16.5 1.16)
version_ge() {
  local -a a b
  IFS=. read -r -a a <<<"${1#v}"
  IFS=. read -r -a b <<<"${2#v}"
  local i x y
  for i in 0 1 2; do
    x="${a[$i]:-0}"; y="${b[$i]:-0}"
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
    [ "${x:-0}" -gt "${y:-0}" ] && return 0
    [ "${x:-0}" -lt "${y:-0}" ] && return 1
  done
  return 0
}

# --- kubectl 접속 ---------------------------------------------------------------
# kube_login 리소스그룹 클러스터
#   이 스크립트 전용 임시 kubeconfig 를 만들어 KUBECONFIG 로 지정합니다 (내 ~/.kube/config 는 수정하지 않습니다).
#   Lab 05 에서 한 `az aks get-credentials` + `kubelogin convert-kubeconfig` 와 같은 동작입니다.
kube_login() {
  [ -z "${_KUBECONFIG_TMP:-}" ] || rm -f "$_KUBECONFIG_TMP" # 여러 스택을 검증할 때 이전 임시 파일을 지웁니다.
  _KUBECONFIG_TMP="$(mktemp "${TMPDIR:-/tmp}/aks-lab-kubeconfig.XXXXXX")"
  export KUBECONFIG="$_KUBECONFIG_TMP"
  az aks get-credentials -g "$1" -n "$2" --file "$KUBECONFIG" --overwrite-existing >/dev/null 2>&1 &&
    kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
}

_aks_lab_cleanup() { [ -z "${_KUBECONFIG_TMP:-}" ] || rm -f "$_KUBECONFIG_TMP"; }
trap _aks_lab_cleanup EXIT
```
<!-- /tf:include -->

**`scripts/verify.sh`** — 스택별 검증 스크립트를 호출하는 진입점

<!-- tf:include path="scripts/verify.sh" -->
```bash title="scripts/verify.sh"
#!/usr/bin/env bash
# 실습 결과 검증 (읽기 전용): 각 스택이 설계한 대로 만들어졌는지 az / kubectl 로 확인합니다.
# 이름은 스택의 `terraform output` 에서 찾으므로, 그 스택에서 init + apply 를 마친 뒤 실행하세요.
#
# 사용법:
#   scripts/verify.sh                       # apply 한 모든 스택 (아직 안 한 스택은 건너뜀)
#   scripts/verify.sh 05-aks                # 특정 스택만
#   scripts/verify.sh 03-network 04-platform
#
# 필요: terraform, az(로그인), jq   (05 이후: kubectl, kubelogin)
# 종료 코드: 모두 통과 0 / 실패가 있으면 1 / 사용법 오류 2
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

ALL_STACKS="02-bootstrap 03-network 04-platform 05-aks 06-workload 07-ingress 08-governance 10-aks-automatic"

case "${1:-}" in
  -h | --help)
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

require_cmd terraform az jq || exit 2
if ! az account show >/dev/null 2>&1; then
  echo "az login 이 필요합니다." >&2
  exit 2
fi

explicit=0
stacks="$ALL_STACKS"
if [ "$#" -gt 0 ]; then
  explicit=1
  stacks="$*"
fi
for s in $stacks; do
  case " $ALL_STACKS " in
    *" $s "*) ;;
    *)
      echo "알 수 없는 스택: $s (사용 가능: $ALL_STACKS)" >&2
      exit 2
      ;;
  esac
done

info "구독: $(az account show --query "join(' ', [name, id])" -o tsv 2>/dev/null)"

for s in $stacks; do
  if ! tf_applied "$s"; then
    section "$s"
    if [ "$explicit" -eq 1 ]; then
      fail "아직 apply 하지 않았거나 init 이 필요합니다 (terraform -chdir=terraform/$s init -backend-config=../backend.hcl)"
    else
      skip "아직 apply 하지 않은 스택이라 건너뜁니다"
    fi
    continue
  fi
  # shellcheck source=/dev/null
  source "${HERE}/verify/${s}.sh"
  verify_stack
done

summary
```
<!-- /tf:include -->

**`.shellcheckrc`** — ShellCheck 설정 (`source` 경로를 스크립트 위치 기준으로 해석)

<!-- tf:include path=".shellcheckrc" -->
```text title=".shellcheckrc"
# ShellCheck 설정: source 경로를 스크립트 위치 기준으로 해석합니다.
#   shellcheck scripts/*.sh scripts/lib/*.sh scripts/verify/*.sh tools/*.sh
source-path=SCRIPTDIR
external-sources=true
```
<!-- /tf:include -->
