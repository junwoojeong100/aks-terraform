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

variable "namespace" {
  description = "웹 앱과 Gateway 를 배포할 네임스페이스. Gateway 가 만드는 Envoy 프록시도 같은 네임스페이스에 생깁니다."
  type        = string
  default     = "web"
}

variable "app_image" {
  description = <<-EOT
    웹 앱 이미지. 비워 두면 <acr>.azurecr.io/demo/aspnetapp:v1 을 사용합니다.
    사전에 `az acr import` 로 ACR 에 넣어 두어야 합니다 (Lab 07 참고).
  EOT
  type        = string
  default     = ""
}

variable "internal_gateway" {
  description = <<-EOT
    true 이면 Gateway 를 내부 로드밸런서(snet-ingress 서브넷의 사설 IP)로 노출합니다.
    false(기본값)이면 공인 IP 로 노출합니다 (ALB internet-facing / internal 스킴 선택과 같은 개념).
  EOT
  type        = bool
  default     = false
}

variable "ingress_subnet_name" {
  description = "internal_gateway=true 일 때 로드밸런서 프런트엔드 IP 를 할당할 서브넷 이름 (03-network 의 snet-ingress)"
  type        = string
  default     = "snet-ingress"
}
