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
