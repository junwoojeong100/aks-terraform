variable "workload" {
  description = "워크로드 이름 (소문자/숫자 3~8자). 예: aksdemo"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.workload))
    error_message = "workload는 소문자/숫자 3~8자여야 합니다 (Key Vault·Storage 이름 길이 제한 때문)."
  }
}

variable "environment" {
  description = "환경 구분 (dev, test, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment는 dev, test, prod 중 하나여야 합니다."
  }
}

variable "location" {
  description = "Azure 리전 이름 (예: koreacentral)"
  type        = string
}

variable "subscription_id" {
  description = "구독 ID. 전역 고유 이름(ACR, Key Vault, Storage)에 붙일 해시 접미사 계산에 사용합니다."
  type        = string
}
