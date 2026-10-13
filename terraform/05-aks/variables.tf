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
    Kubernetes API 서버에 접근을 허용할 관리자 공인 IP (CIDR 목록).
    예: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
    enable_private_cluster = true 이면 사용하지 않습니다.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "allowed_ip_ranges 에 CIDR 을 1개 이상 지정하세요. 예: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    클러스터를 "처음 만들 때" 사용할 Kubernetes 버전 (minor alias). 2026-10 기준 GA 최신은 1.36, AKS 기본값은 1.35 입니다.
    생성 이후의 버전은 AKS 가 관리하므로(patch 는 automatic_upgrade_channel = "patch", minor 는 Lab 09 절차) Terraform 은 이 값의 변경을 무시합니다.
    확인: az aks get-versions --location koreacentral -o table
  EOT
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version 은 1.36 또는 1.36.4 형식이어야 합니다."
  }
}

variable "sku_tier" {
  description = "AKS 컨트롤 플레인 등급. Standard = 업타임 SLA(99.95%, 가용 영역 사용 시) 포함. Free 는 SLA 없음."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier 는 Free, Standard, Premium 중 하나여야 합니다."
  }
}

variable "enable_private_cluster" {
  description = <<-EOT
    true 이면 API 서버를 사설 IP 로만 노출합니다(완전 private).
    이 경우 kubectl/Terraform kubernetes provider 는 VNet 안(또는 VPN/Bastion)에서만 접근 가능합니다.
    실습 기본값은 false: API Server VNet Integration + authorized IP ranges.
  EOT
  type        = bool
  default     = false
}

variable "zones" {
  description = "노드 풀을 분산 배치할 가용 영역"
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "system_node_vm_size" {
  description = "System 노드 풀 VM 크기 (최소 4 vCPU 권장)"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "system_node_min_count" {
  description = "System 노드 풀 최소 노드 수 (가용 영역 3곳에 1대씩 = 3)"
  type        = number
  default     = 3
}

variable "system_node_max_count" {
  description = "System 노드 풀 최대 노드 수"
  type        = number
  default     = 5
}

variable "user_node_vm_size" {
  description = "User 노드 풀 VM 크기"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "user_node_min_count" {
  description = "User 노드 풀 최소 노드 수 (가용 영역 3곳에 1대씩 = 3)"
  type        = number
  default     = 3
}

variable "user_node_max_count" {
  description = "User 노드 풀 최대 노드 수"
  type        = number
  default     = 6
}

variable "enable_spot_pool" {
  description = "Spot VM 노드 풀 추가 여부 (EC2 Spot 에 해당, 배치/내결함성 워크로드용)"
  type        = bool
  default     = false
}

variable "enable_gateway_api" {
  description = "Managed Gateway API CRD + 애플리케이션 라우팅 Gateway API 구현(approuting-istio) 활성화"
  type        = bool
  default     = true
}

variable "enable_defender" {
  description = "클러스터에 Microsoft Defender for Containers 프로필 연결 (구독 단위 플랜은 08-governance 에서 켭니다)"
  type        = bool
  default     = false
}

variable "grant_current_user_admin" {
  description = <<-EOT
    true 이면 terraform 을 실행하는 "현재 로그인 주체"에게 클러스터 관리자(Azure RBAC Cluster Admin) 권한을 줍니다. 실습용 기본값입니다.
    팀/CI 환경에서는 false 로 두고 admin_principal_ids 에 Entra 그룹을 지정하세요(실행 주체가 바뀌어도 권한이 흔들리지 않습니다).
  EOT
  type        = bool
  default     = true

  validation {
    condition     = var.grant_current_user_admin || length(var.admin_principal_ids) > 0
    error_message = "grant_current_user_admin = false 이면 admin_principal_ids 에 관리자 그룹/사용자를 1개 이상 지정하세요. (로컬 계정이 비활성화되어 있어 관리자가 없으면 아무도 클러스터에 접근할 수 없습니다.)"
  }
}

variable "admin_principal_ids" {
  description = "클러스터 관리자 권한(Azure RBAC Cluster Admin)을 추가로 줄 Entra 사용자/그룹 Object ID. 팀 환경에서는 개인 대신 그룹을 권장합니다."
  type        = set(string)
  default     = []
}

variable "maintenance_utc_offset" {
  description = "유지보수 창(planned maintenance) 기준 시간대"
  type        = string
  default     = "+09:00"
}

variable "pod_cidr" {
  description = "Azure CNI Overlay Pod CIDR. VNet / 온프레미스 대역과 겹치면 안 됩니다. 03-network 의 pod_cidr(노드 NSG 의 허용 규칙)와 같은 값을 쓰세요."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "kube-dns Service IP (service_cidr 안의 주소)"
  type        = string
  default     = "10.0.0.10"
}
