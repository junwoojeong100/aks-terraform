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
