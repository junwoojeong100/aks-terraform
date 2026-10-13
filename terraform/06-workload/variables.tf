variable "workload" {
  description = "Workload name (3–8 lowercase letters or digits)"
  type        = string
  default     = "aksdemo"
}

variable "environment" {
  description = "Environment (dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "koreacentral"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "app_namespace" {
  description = "Kubernetes namespace to deploy the demo app into"
  type        = string
  default     = "demo"
}

variable "app_service_account" {
  description = "Name of the Kubernetes ServiceAccount to link with Workload Identity"
  type        = string
  default     = "workload-sa"
}

variable "app_image" {
  description = <<-EOT
    Demo container image. If left empty, <acr>.azurecr.io/demo/busybox:2.0 is used.
    Import it into ACR beforehand with `az acr import` (see Lab 06).
  EOT
  type        = string
  default     = ""
}
