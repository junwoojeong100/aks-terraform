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
