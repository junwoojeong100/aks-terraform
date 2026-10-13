# Lab 08. 거버넌스와 보안: Azure Policy · Defender · 잠금 · 예산

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 30분 (정책 동기화 대기 포함) | 기본 구성은 무료. Defender 플랜은 vCore 당 요금(선택) | `terraform/08-governance` | [05. AKS 클러스터](05-aks.md) |

## 이번 실습에서 만드는 것

![거버넌스는 어느 범위에 거는가](diagrams/governance-scopes.svg)

| 계층 | 리소스 | 효과 |
|---|---|---|
| **클러스터 설정 점검** | 내장 정책 6개(로컬 계정 차단, authorized IP, RBAC, 관리 ID, Policy 애드온, Defender 프로필) | 클러스터가 Best practice 를 만족하는지 **감사(Audit)** |
| **클러스터 안(Admission) 점검** | Pod 보안 이니셔티브 `baseline`, `restricted` | 비루트 실행, 권한 상승 금지, 리소스 제한 등을 `Audit` 또는 `Deny` |
| **위협 탐지** | `azurerm_security_center_subscription_pricing` (Defender for Containers) | 런타임 위협·이미지 취약점·구성 오류 (선택) |
| **삭제 방지** | `azurerm_management_lock` | 네트워크/플랫폼 RG 실수 삭제 방지 (선택) |
| **비용 가드레일** | `azurerm_consumption_budget_subscription` | 태그(`workload`) 기준 월 예산 알림 (선택) |

## AWS 경험자를 위한 비교

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| SCP (조직 권한 상한) | **Azure Policy**(+ RBAC `deny assignments`) | SCP 는 "IAM 권한 상한", Azure Policy 는 *리소스 속성/요청 내용*을 평가해 감사·거부·수정합니다. |
| AWS Config 규칙 / Conformance pack | **Policy 정의 / 이니셔티브(policySet)** + 준수 상태 | 이니셔티브가 conformance pack 에 해당. 내장 정의가 매우 많습니다. |
| Kyverno / OPA Gatekeeper | **Azure Policy for Kubernetes**(Gatekeeper v3 기반 애드온) | 같은 `azurerm_resource_group_policy_assignment` 로 할당하면 Gatekeeper 제약(Constraint)으로 클러스터에 동기화됩니다. |
| GuardDuty(EKS) / Inspector(ECR) / Security Hub | **Microsoft Defender for Containers** + Defender for Cloud | 구독 단위 플랜 + 클러스터 `microsoft_defender` 프로필. |
| CloudFormation Termination Protection / SCP deny | **리소스 잠금(CanNotDelete / ReadOnly)** | 잠금은 *삭제 자체*를 막습니다(소유자라도). `terraform destroy` 전에 해제 필요. |
| AWS Budgets | **Cost Management 예산** | 이메일/Action group 알림. 태그 필터로 워크로드 단위 추적. |

## 설계 결정 (Best practice)

| 결정 | 이유 |
|---|---|
| **Audit → Deny 로 단계적 적용** (`policy_effect`) | 처음부터 Deny 로 켜면 기존 워크로드가 막힙니다. 감사 결과를 보고 예외를 정리한 뒤 Deny 로 올립니다. |
| 할당 범위 = **클러스터 리소스 그룹** | 실습 범위를 한정. 운영에서는 관리 그룹/구독으로 올려 모든 클러스터에 상속시킵니다. |
| `excludedNamespaces` 에 시스템 네임스페이스 | `kube-system`, `gatekeeper-system`, `aks-istio-system` 등 AKS 가 관리하는 네임스페이스는 평가 제외. |
| `restricted` 이니셔티브는 항상 Audit | "다음 단계(더 엄격한 표준)에 얼마나 가까운지" 를 보여주는 용도. |
| 정책 정의/GUID 를 코드에 명시 | 내장 정의 ID 는 전 세계 공통입니다. `az policy definition show --name <GUID>` 로 항상 확인할 수 있습니다. |
| 구독 단위 Defender 플랜/잠금/예산은 **기본 off** | 구독 전체 영향/비용/삭제 방해 요소이므로 명시적으로 켭니다. |

> [!NOTE]
> **AKS Automatic** 은 위 정책 중 상당수가 *Deployment Safeguards* 와 *Pod Security Standards(baseline)* 로 **enforce 모드가 기본 적용**됩니다 → [Lab 10](10-aks-automatic.md).

## 코드

<!-- tf:include path="terraform/08-governance/versions.tf" -->
```hcl title="terraform/08-governance/versions.tf"
terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    key              = "08-governance.tfstate"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/08-governance/providers.tf" -->
```hcl title="terraform/08-governance/providers.tf"
provider "azurerm" {
  # subscription_id 는 ARM_SUBSCRIPTION_ID 환경 변수에서 읽습니다.
  resource_provider_registrations = "none"

  features {}
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/08-governance/variables.tf" -->
```hcl title="terraform/08-governance/variables.tf"
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

variable "policy_effect" {
  description = <<-EOT
    Pod 보안 이니셔티브(baseline/restricted)의 효과.
    Audit = 위반을 기록만 함 (실습 기본값), Deny = 위반 리소스 생성을 차단.
    Deny 는 클러스터에 이미 배포하려는 워크로드가 정책을 만족하는지 확인한 뒤에 켜세요.
  EOT
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.policy_effect)
    error_message = "policy_effect 는 Audit, Deny, Disabled 중 하나여야 합니다."
  }
}

variable "enable_defender_plan" {
  description = <<-EOT
    구독 단위 Microsoft Defender for Containers 플랜 활성화.
    구독 전체에 영향을 주고 vCore 단위 요금이 발생하므로 기본값은 false 입니다.
  EOT
  type        = bool
  default     = false
}

variable "enable_resource_locks" {
  description = "네트워크/플랫폼 리소스 그룹에 CanNotDelete 잠금 설정 (실습 정리 전에 먼저 해제해야 합니다)."
  type        = bool
  default     = false
}

variable "enable_budget" {
  description = "워크로드 태그 기준 월 예산 알림 생성 (budget_alert_emails 필요)"
  type        = bool
  default     = false
}

variable "budget_amount" {
  description = "월 예산 금액 (구독 청구 통화 기준)"
  type        = number
  default     = 100
}

variable "budget_alert_emails" {
  description = "예산 알림을 받을 이메일 주소 목록"
  type        = list(string)
  default     = []
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/08-governance/main.tf" -->
```hcl title="terraform/08-governance/main.tf"
data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

data "azurerm_resource_group" "aks" {
  name = module.naming.names.rg_aks
}

data "azurerm_resource_group" "network" {
  name = module.naming.names.rg_network
}

data "azurerm_resource_group" "platform" {
  name = module.naming.names.rg_platform
}
```
<!-- /tf:include -->

**`policy.tf`** — Azure Policy 할당

<!-- tf:include path="terraform/08-governance/policy.tf" -->
```hcl title="terraform/08-governance/policy.tf"
# ---------------------------------------------------------------------------
# Azure Policy for AKS  (AWS Config 규칙 + SCP + Kyverno/Gatekeeper 를 합친 역할)
#
#   - 클러스터 "설정" 점검: ARM 레벨 정책 (예: 로컬 계정 차단, authorized IP 설정 여부) → AWS Config 규칙과 유사
#   - 클러스터 "안" 점검  : Azure Policy 애드온(Gatekeeper)이 쿠버네티스 admission 단계에서 평가 → Kyverno/OPA 와 유사
#
# 할당 범위(scope)는 클러스터가 있는 리소스 그룹입니다. 구독/관리 그룹 단위로 올리면 모든 클러스터에 상속됩니다.
# ---------------------------------------------------------------------------
locals {
  # 정책 평가에서 제외할 시스템 네임스페이스 (이니셔티브 기본값 + AKS 관리형 애드온)
  policy_excluded_namespaces = [
    "kube-system",
    "gatekeeper-system",
    "azure-arc",
    "azure-extensions-usage-system",
    "aks-istio-system",
    "app-routing-system",
  ]

  # 내장 정책 이니셔티브(policySet) : Pod 보안 표준 (Linux)
  pod_security_initiatives = {
    baseline = {
      id           = "/providers/Microsoft.Authorization/policySetDefinitions/a8640138-9b0a-4a28-b8cb-1666c838647d"
      display_name = "AKS Pod 보안 baseline (Linux)"
    }
    restricted = {
      id           = "/providers/Microsoft.Authorization/policySetDefinitions/42b8ef37-b724-4e24-bbc8-7a7708edfe00"
      display_name = "AKS Pod 보안 restricted (Linux)"
    }
  }

  # 내장 정책 정의: 클러스터 설정 점검 (모두 Audit 전용)
  cluster_config_policies = {
    local-auth-disabled = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/993c2fcd-2b29-49d2-9eb0-df2c3a730c32"
      display_name = "AKS 클러스터는 로컬 인증 방식이 비활성화되어야 함"
    }
    policy-addon-enabled = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/0a15ec92-a229-4763-bb14-0ea34a568f8d"
      display_name = "AKS 에 Azure Policy 애드온이 설치되어 있어야 함"
    }
    rbac-enabled = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/ac4a19c2-fa67-49b4-8ae5-0b2e78c49457"
      display_name = "Kubernetes RBAC 가 사용되어야 함"
    }
    authorized-ip-ranges = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/0e246bcf-5f6f-4f87-bc6f-775d4712c7ea"
      display_name = "API 서버 authorized IP ranges 가 정의되어야 함"
    }
    managed-identity = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/da6e2401-19da-4532-9141-fb8fbde08431"
      display_name = "AKS 클러스터는 관리 ID 를 사용해야 함"
    }
    defender-profile = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/a1840de2-8088-4ea8-b153-b4c723e9cb01"
      display_name = "AKS 클러스터에 Defender 프로필이 활성화되어야 함"
    }
  }
}

resource "azurerm_resource_group_policy_assignment" "pod_security" {
  for_each = local.pod_security_initiatives

  name                 = "aks-pod-security-${each.key}"
  display_name         = each.value.display_name
  resource_group_id    = data.azurerm_resource_group.aks.id
  policy_definition_id = each.value.id

  # baseline 만 var.policy_effect 를 따르고, restricted 는 항상 Audit 로 두어 "다음 단계 준비 상태"를 보여 줍니다.
  parameters = jsonencode({
    effect = {
      value = each.key == "baseline" ? var.policy_effect : "Audit"
    }
    excludedNamespaces = {
      value = local.policy_excluded_namespaces
    }
  })

  non_compliance_message {
    content = "Pod 보안 표준을 위반했습니다. 비루트 실행, 권한 상승 금지, 리소스 제한 등을 확인하세요."
  }
}

resource "azurerm_resource_group_policy_assignment" "cluster_config" {
  for_each = local.cluster_config_policies

  name                 = "aks-${each.key}"
  display_name         = each.value.display_name
  resource_group_id    = data.azurerm_resource_group.aks.id
  policy_definition_id = each.value.id
}
```
<!-- /tf:include -->

**`security.tf`** — Defender 플랜, 리소스 잠금

<!-- tf:include path="terraform/08-governance/security.tf" -->
```hcl title="terraform/08-governance/security.tf"
# ---------------------------------------------------------------------------
# Microsoft Defender for Containers  (GuardDuty EKS Protection + Inspector(ECR 스캔) + Security Hub 에 해당)
#   - 구독 단위 "플랜" 을 켜면, 05-aks 의 enable_defender = true (microsoft_defender 프로필)와 함께 동작합니다.
#   - 기능: 런타임 위협 탐지, ACR 이미지 취약점 스캔, 구성 오류(Kubernetes 보안 태세) 평가
# ---------------------------------------------------------------------------
resource "azurerm_security_center_subscription_pricing" "containers" {
  count = var.enable_defender_plan ? 1 : 0

  resource_type = "Containers"
  tier          = "Standard"
}

# ---------------------------------------------------------------------------
# 리소스 잠금 (CloudFormation 스택 정책 / Termination Protection 과 유사)
# ---------------------------------------------------------------------------
resource "azurerm_management_lock" "network" {
  count = var.enable_resource_locks ? 1 : 0

  name       = "lock-do-not-delete"
  scope      = data.azurerm_resource_group.network.id
  lock_level = "CanNotDelete"
  notes      = "네트워크는 여러 스택이 공유하므로 실수로 삭제하지 못하게 합니다."
}

resource "azurerm_management_lock" "platform" {
  count = var.enable_resource_locks ? 1 : 0

  name       = "lock-do-not-delete"
  scope      = data.azurerm_resource_group.platform.id
  lock_level = "CanNotDelete"
  notes      = "ACR / Key Vault / 모니터링 공용 서비스 보호"
}
```
<!-- /tf:include -->

**`budget.tf`** — 예산 알림

<!-- tf:include path="terraform/08-governance/budget.tf" -->
```hcl title="terraform/08-governance/budget.tf"
# ---------------------------------------------------------------------------
# 예산 알림 (AWS Budgets 에 해당)
# 구독 전체에서 workload 태그가 일치하는 비용만 추적합니다. AKS 노드 리소스 그룹의 리소스도
# 클러스터 태그를 상속하므로 함께 집계됩니다.
# ---------------------------------------------------------------------------
resource "time_static" "budget_start" {}

locals {
  # 예산 시작일은 "이번 달 1일 00:00Z" 여야 합니다. 최초 생성 시점의 달로 고정합니다.
  budget_start_date = formatdate("YYYY-MM-01'T'00:00:00'Z'", time_static.budget_start.rfc3339)
}

resource "azurerm_consumption_budget_subscription" "workload" {
  count = var.enable_budget ? 1 : 0

  name            = "budget-${module.naming.base}"
  subscription_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = local.budget_start_date
  }

  filter {
    tag {
      name   = "workload"
      values = [var.workload]
    }
  }

  notification {
    enabled        = true
    threshold      = 80
    threshold_type = "Actual"
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThan"
    contact_emails = var.budget_alert_emails
  }

  lifecycle {
    precondition {
      condition     = length(var.budget_alert_emails) > 0
      error_message = "enable_budget = true 이면 budget_alert_emails 에 이메일을 1개 이상 지정하세요."
    }
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/08-governance/outputs.tf" -->
```hcl title="terraform/08-governance/outputs.tf"
output "policy_assignments" {
  description = "클러스터 리소스 그룹에 할당된 정책 이름"
  value = concat(
    [for a in azurerm_resource_group_policy_assignment.pod_security : a.name],
    [for a in azurerm_resource_group_policy_assignment.cluster_config : a.name],
  )
}

output "compliance_command" {
  description = "정책 준수 상태 조회 (평가는 최초 할당 후 최대 수십 분 소요)"
  value       = "az policy state summarize --resource-group ${module.naming.names.rg_aks}"
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/08-governance/tests/plan.tftest.hcl" -->
```hcl title="terraform/08-governance/tests/plan.tftest.hcl"
# Azure 없이 plan 로직만 검증: terraform -chdir=terraform/08-governance test
mock_provider "azurerm" {
  source = "../mocks"
}

mock_provider "time" {}

run "plan_defaults" {
  command = plan

  assert {
    condition     = length(azurerm_security_center_subscription_pricing.containers) == 0
    error_message = "기본값에서는 구독 단위 Defender 플랜을 켜지 않습니다."
  }

  assert {
    condition     = length(azurerm_resource_group_policy_assignment.pod_security) == 2
    error_message = "baseline / restricted 이니셔티브 2개가 할당되어야 합니다."
  }
}

run "plan_everything_enabled" {
  command = plan

  variables {
    enable_defender_plan  = true
    enable_resource_locks = true
    enable_budget         = true
    budget_alert_emails   = ["ops@example.com"]
    policy_effect         = "Deny"
  }

  assert {
    condition     = length(azurerm_management_lock.network) == 1 && length(azurerm_consumption_budget_subscription.workload) == 1
    error_message = "잠금과 예산이 생성되어야 합니다."
  }
}

run "budget_requires_email" {
  command = plan

  variables {
    enable_budget = true
  }

  expect_failures = [azurerm_consumption_budget_subscription.workload]
}
```
<!-- /tf:include -->

## 실습 따라하기

### 1단계. 기본(Audit) 적용

```bash
cd terraform/08-governance
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan        # 정책 할당 8개
terraform apply tfplan
```

### 2단계. 정책이 클러스터로 동기화되었는지 확인

Azure Policy 애드온은 약 15분마다 할당을 동기화합니다. 처음에는 시간이 걸립니다.

```bash
# 클러스터에 Gatekeeper 제약(Constraint)이 생겼는가
kubectl get constrainttemplates | head
kubectl get constraints | head -20

# 준수 상태 요약 (평가에는 최대 수십 분)
$(terraform output -raw compliance_command)
az policy state list -g "$(terraform -chdir=../05-aks output -raw resource_group_name)" \
  --filter "complianceState eq 'NonCompliant'" --query "[].{policy:policyDefinitionName, resource:resourceId}" -o table
```

기대 결과: 기본 구성에서는 `authorized-ip-ranges`(O), `local-auth-disabled`(O) 등이 **Compliant**, Defender 프로필 정책은 `enable_defender=false` 이므로 **NonCompliant** 로 나옵니다 → 감사가 의도대로 동작하는 것입니다.

### 3단계. Deny 효과 체험

```bash
terraform apply -var policy_effect=Deny      # 애드온이 동기화될 때까지 ~15분 대기

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: bad-pod, namespace: web }
spec:
  containers:
  - name: bad
    image: mcr.microsoft.com/cbl-mariner/busybox:2.0
    command: ["sleep","3600"]
    securityContext: { privileged: true }
EOF
# → admission webhook "validation.gatekeeper.sh" denied the request: ... Privileged container is not allowed
```

확인 후에는 `terraform apply` (기본값 Audit)로 되돌리세요. Deny 상태에서는 06/07 에서 배포한 앱도 정책을 만족해야 합니다(이 가이드의 앱은 만족하도록 작성되었습니다).

### 4단계. (선택) Defender / 예산 / 잠금

```bash
# Defender for Containers: 구독 단위 플랜 + 클러스터 프로필
terraform apply -var enable_defender_plan=true
terraform -chdir=../05-aks apply -var enable_defender=true
az security pricing show -n Containers --query pricingTier -o tsv     # Standard

# 월 예산 알림 (이메일)
terraform apply -var enable_budget=true -var 'budget_alert_emails=["you@example.com"]' -var budget_amount=150

# 삭제 방지 잠금
terraform apply -var enable_resource_locks=true
az group delete -n "$(terraform -chdir=../03-network output -raw resource_group_name)" --yes   # → ScopeLocked 로 실패해야 정상
```

> [!WARNING]
> 잠금(`enable_resource_locks`)을 켠 채로 정리하면 `terraform destroy` 가 실패합니다. **정리 전에 먼저 `-var enable_resource_locks=false` 로 apply** 하세요 → [Lab 11](11-cleanup.md).

### 자동 검증 스크립트

정책 할당과 준수 상태, Defender 플랜, 리소스 잠금을 확인합니다. 정책 효과가 기본값 `Audit` 이면 비준수 리소스가 있어도 **경고(!)** 로만 표시합니다 (평가는 할당 직후 최대 수십 분 걸립니다).

```bash
cd ../..                          # 저장소 루트에서 실행
scripts/verify.sh 08-governance
```

<!-- tf:include path="scripts/verify/08-governance.sh" -->
```bash title="scripts/verify/08-governance.sh"
#!/usr/bin/env bash
# Lab 08 검증: Azure Policy 할당 · 준수 상태 · Defender · 리소스 잠금을 확인합니다 (읽기 전용).
#   AWS 비교: AWS Config/SCP + Security Hub/GuardDuty + 리소스 삭제 방지(termination protection)
#   정책은 기본값이 Audit(보고만)이라 비준수 리소스가 있어도 "경고"로만 표시합니다.
# 사용법: scripts/verify.sh 08-governance
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg names n a state tier g count
  rg="$(tf_out 05-aks resource_group_name)"
  names="$(terraform -chdir="${TF_DIR}/08-governance" output -json policy_assignments 2>/dev/null | jq -r '.[]?' 2>/dev/null)"

  section "08-governance · 정책 할당 (${rg:-?})"
  if [ -z "$names" ]; then
    fail "policy_assignments 출력을 읽을 수 없습니다. 08-governance 에서 init/apply 를 마쳤나요?"
    return
  fi
  for n in $names; do
    a="$(azj policy assignment show -n "$n" -g "$rg")"
    expect_set "정책 할당 $n" "$(jv "$a" .displayName)"
  done

  # 준수 평가는 할당 직후 최대 수십 분이 걸립니다. 비준수가 있어도 Audit 모드면 배포는 막지 않습니다.
  state="$(azj policy state summarize -g "$rg")"
  if [ -z "$state" ]; then
    warn "준수 상태를 아직 조회할 수 없습니다 (할당 직후에는 평가 전일 수 있습니다)"
  else
    jq_warn "비준수 리소스가 없음 (현재 $(jv "$state" '.results.nonCompliantResources // 0')개)" "$state" '(.results.nonCompliantResources // 0) == 0'
  fi

  section "08-governance · Defender · 잠금"
  tier="$(az security pricing show -n Containers --query pricingTier -o tsv 2>/dev/null)"
  if [ "$tier" = "Standard" ]; then
    pass "Defender for Containers 구독 플랜 켜짐"
  else
    info "Defender for Containers 구독 플랜: ${tier:-확인 불가} (enable_defender_plan = false 가 기본값)"
  fi
  for g in "$(tf_out 03-network resource_group_name)" "$(tf_out 04-platform resource_group_name)"; do
    [ -n "$g" ] || continue
    count="$(az lock list -g "$g" --query 'length(@)' -o tsv 2>/dev/null)"
    info "리소스 잠금 $g: ${count:-0}개 (enable_resource_locks = false 가 기본값)"
  done
}

# 직접 실행(scripts/verify/08-governance.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## 자주 만나는 문제

| 증상 | 원인 / 해결 |
|---|---|
| `AuthorizationFailed ... policyAssignments/write` | 정책 할당 권한(Resource Policy Contributor/Owner) 부족. |
| `kubectl get constraints` 결과가 비어 있음 | 애드온 동기화 대기(최대 15분). `kubectl get pods -n kube-system \| grep azure-policy`, `kubectl get pods -n gatekeeper-system` 로 파드 상태를 확인하고 `azure_policy_enabled = true` 여부를 점검하세요. |
| 준수 상태가 계속 `NotStarted` | 최초 평가는 느립니다(수십 분). `az policy state trigger-scan -g <rg>` 로 수동 평가를 요청할 수 있습니다. |
| 예산 생성 오류 `start_date` | 예산 시작일은 **당월 1일** 이어야 합니다(코드가 `time_static` 으로 자동 계산). |
| Defender 플랜 활성화 후 비용 증가 | 구독 내 모든 AKS 노드 vCore 에 과금됩니다. 실습 후 `-var enable_defender_plan=false` 로 끄세요. |

다음 → [Lab 09. Day-2 운영: 업그레이드 · 스케일링 · 테스트](09-operations.md)
