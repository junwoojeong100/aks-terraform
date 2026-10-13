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

variable "namespace" {
  description = "Namespace for the web app and Gateway. The Envoy proxy that the Gateway creates also runs in this namespace."
  type        = string
  default     = "web"
}

variable "app_image" {
  description = <<-EOT
    Web app image. If left empty, <acr>.azurecr.io/demo/aspnetapp:v1 is used.
    Import it into ACR beforehand with `az acr import` (see Lab 07).
  EOT
  type        = string
  default     = ""
}

variable "internal_gateway" {
  description = <<-EOT
    If true, the Gateway is exposed through an internal load balancer (private IP in the snet-ingress subnet).
    If false (default), it is exposed through a public IP (like choosing the ALB internet-facing vs. internal scheme).
  EOT
  type        = bool
  default     = false
}

variable "ingress_subnet_name" {
  description = "Subnet name for the load balancer frontend IP when internal_gateway=true (snet-ingress from 03-network)"
  type        = string
  default     = "snet-ingress"
}
