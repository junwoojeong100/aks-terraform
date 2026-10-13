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
