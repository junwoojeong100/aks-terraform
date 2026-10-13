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
  description = "Azure 리전 (AKS Automatic 지원 리전이어야 합니다. koreacentral 지원)"
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
    Kubernetes API 서버에 접근을 허용할 관리자 공인 IP (CIDR 목록).
    예: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "allowed_ip_ranges 에 CIDR 을 1개 이상 지정하세요. 예: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "grant_current_user_admin" {
  description = <<-EOT
    true 이면 terraform 을 실행하는 "현재 로그인 주체"에게 클러스터 관리자(Azure RBAC Cluster Admin) 권한을 줍니다. 실습용 기본값입니다.
    팀/CI 환경에서는 false 로 두고 admin_principal_ids 에 Entra 그룹을 지정하세요.
  EOT
  type        = bool
  default     = true

  validation {
    condition     = var.grant_current_user_admin || length(var.admin_principal_ids) > 0
    error_message = "grant_current_user_admin = false 이면 admin_principal_ids 에 관리자 그룹/사용자를 1개 이상 지정하세요. (AKS Automatic 은 로컬 계정이 없어 관리자가 없으면 아무도 클러스터에 접근할 수 없습니다.)"
  }
}

variable "admin_principal_ids" {
  description = "클러스터 관리자 권한(Azure RBAC Cluster Admin)을 추가로 줄 Entra 사용자/그룹 Object ID. 팀 환경에서는 개인 대신 그룹을 권장합니다."
  type        = set(string)
  default     = []
}

variable "use_byo_network" {
  description = <<-EOT
    false(기본값) : AKS 가 VNet 까지 관리하는 "managed VNet" 모드 - 가장 간단합니다.
    true          : 직접 만든 VNet/서브넷 사용 (BYO VNet) - 기존 네트워크/온프레미스 연동이 필요할 때.
  EOT
  type        = bool
  default     = false
}

variable "vnet_cidr" {
  description = "use_byo_network = true 일 때 만들 VNet 주소 공간"
  type        = string
  default     = "10.20.0.0/16"
}
