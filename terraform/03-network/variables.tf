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

variable "address_space" {
  description = "VNet 주소 공간. 온프레미스/피어링 대상 네트워크와 겹치지 않게 정하세요."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidrs" {
  description = <<-EOT
    서브넷 CIDR.
    - aks_nodes: 노드 IP 전용 (Azure CNI Overlay 이므로 Pod IP 는 여기서 쓰지 않습니다)
    - aks_apiserver: API Server VNet Integration 용. 최소 /28, AKS 전용
    - ingress: 내부 로드밸런서 프런트엔드 IP (Gateway)
    - private_endpoints: ACR / Key Vault 등 Private Endpoint
  EOT
  type = object({
    aks_nodes         = string
    aks_apiserver     = string
    ingress           = string
    private_endpoints = string
  })
  default = {
    aks_nodes         = "10.10.0.0/24"
    aks_apiserver     = "10.10.1.0/28"
    ingress           = "10.10.2.0/27"
    private_endpoints = "10.10.3.0/27"
  }

  validation {
    condition     = alltrue([for cidr in values(var.subnet_cidrs) : can(cidrhost(cidr, 0))])
    error_message = "subnet_cidrs 의 모든 값은 올바른 CIDR 이어야 하며, address_space 안에 포함되어야 합니다."
  }
}

variable "pod_cidr" {
  description = <<-EOT
    Azure CNI Overlay 의 Pod CIDR. 05-aks 의 pod_cidr 와 같은 값을 쓰세요.
    노드 NSG 에 이 대역을 허용하는 인바운드 규칙을 만듭니다. 기본 규칙만 있을 때는 없어도 통신되지만,
    나중에 Deny 규칙을 추가해도 노드 간 Pod 통신(DNS 포함)이 끊기지 않게 하는 방어용입니다.
  EOT
  type        = string
  default     = "10.244.0.0/16"

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr 는 올바른 CIDR 이어야 합니다. 예: 10.244.0.0/16"
  }
}

variable "nat_gateway_sku" {
  description = "NAT Gateway SKU. StandardV2 는 가용 영역 중복(zone-redundant)이며 대부분의 리전에서 사용 가능합니다."
  type        = string
  default     = "StandardV2"

  validation {
    condition     = contains(["Standard", "StandardV2"], var.nat_gateway_sku)
    error_message = "nat_gateway_sku 는 Standard 또는 StandardV2 여야 합니다."
  }
}

variable "gateway_allowed_source_prefixes" {
  description = <<-EOT
    공용 Gateway(07-ingress 의 internal_gateway = false)로 들어오는 HTTP(80)/HTTPS(443) 를 허용할 출발지.
    Internet 서비스 태그 또는 CIDR 목록이며, 특정 IP 만 열려면 ["203.0.113.10/32"] 처럼 지정하세요.
    내부 Gateway 만 쓴다면 [] 로 두세요. 규칙을 만들지 않으며, VNet 안의 클라이언트는 기본 규칙(AllowVnetInBound)으로 접근합니다.
  EOT
  type        = list(string)
  default     = ["Internet"]

  validation {
    condition     = alltrue([for prefix in var.gateway_allowed_source_prefixes : prefix == "Internet" || can(cidrhost(prefix, 0))])
    error_message = "gateway_allowed_source_prefixes 의 값은 Internet 또는 올바른 CIDR 이어야 합니다."
  }

  # NSG 규칙은 서비스 태그를 목록(복수) 속성에 넣을 수 없습니다.
  validation {
    condition     = !contains(var.gateway_allowed_source_prefixes, "Internet") || length(var.gateway_allowed_source_prefixes) == 1
    error_message = "Internet 서비스 태그는 다른 값과 함께 쓸 수 없습니다. [\"Internet\"] 이거나 CIDR 목록이어야 합니다."
  }
}
