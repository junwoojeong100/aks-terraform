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
