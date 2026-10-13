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

variable "app_namespace" {
  description = "데모 앱을 배포할 쿠버네티스 네임스페이스"
  type        = string
  default     = "demo"
}

variable "app_service_account" {
  description = "Workload Identity 에 연결할 쿠버네티스 ServiceAccount 이름"
  type        = string
  default     = "workload-sa"
}

variable "app_image" {
  description = <<-EOT
    데모 컨테이너 이미지. 비워 두면 <acr>.azurecr.io/demo/busybox:2.0 을 사용합니다.
    사전에 `az acr import` 로 ACR 에 넣어 두어야 합니다 (Lab 06 참고).
  EOT
  type        = string
  default     = ""
}
