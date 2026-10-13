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

variable "nat_gateway_sku" {
  description = "NAT Gateway SKU. StandardV2 는 가용 영역 중복(zone-redundant)이며 대부분의 리전에서 사용 가능합니다."
  type        = string
  default     = "StandardV2"

  validation {
    condition     = contains(["Standard", "StandardV2"], var.nat_gateway_sku)
    error_message = "nat_gateway_sku 는 Standard 또는 StandardV2 여야 합니다."
  }
}
