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
  description = "Azure region (must be a region that supports AKS Automatic; koreacentral is supported)"
  type        = string
  default     = "koreacentral"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "allowed_ip_ranges" {
  description = <<-EOT
    Public IPs of administrators allowed to access the Kubernetes API server (list of CIDRs).
    Example: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "Specify at least one CIDR in allowed_ip_ranges. Example: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "grant_current_user_admin" {
  description = <<-EOT
    If true, grants cluster admin permissions (Azure RBAC Cluster Admin) to the "currently signed-in principal"
    that runs terraform. This is the lab default.
    In team/CI environments, set it to false and specify an Entra group in admin_principal_ids.
  EOT
  type        = bool
  default     = true

  validation {
    condition     = var.grant_current_user_admin || length(var.admin_principal_ids) > 0
    error_message = "When grant_current_user_admin = false, specify at least one admin group/user in admin_principal_ids. (AKS Automatic has no local accounts, so with no admin, nobody can access the cluster.)"
  }
}

variable "admin_principal_ids" {
  description = "Object IDs of additional Entra users/groups to grant cluster admin permissions (Azure RBAC Cluster Admin). In team environments, prefer groups over individuals."
  type        = set(string)
  default     = []
}

variable "use_byo_network" {
  description = <<-EOT
    false (default): "managed VNet" mode where AKS manages the VNet too - the simplest option.
    true           : use your own VNet/subnets (BYO VNet) - when you need to integrate with an existing network/on-premises.
  EOT
  type        = bool
  default     = false
}

variable "vnet_cidr" {
  description = "Address space of the VNet to create when use_byo_network = true"
  type        = string
  default     = "10.20.0.0/16"
}
