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

variable "allowed_ip_ranges" {
  description = <<-EOT
    Public IPs of administrators allowed to access the Kubernetes API server (list of CIDRs).
    Example: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
    Not used when enable_private_cluster = true.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "Specify at least one CIDR in allowed_ip_ranges. Example: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes version (minor alias) used only when the cluster is first created.
    As of 2026-10, the latest GA version is 1.36 and the AKS default is 1.35.
    After creation, AKS manages the version (patches: automatic_upgrade_channel = "patch"; minors: the Lab 09 procedure),
    so Terraform ignores changes to this value.
    To check: az aks get-versions --location koreacentral -o table
  EOT
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}(\\.[0-9]+)?$", var.kubernetes_version))
    error_message = "kubernetes_version must be in the form 1.36 or 1.36.4."
  }
}

variable "sku_tier" {
  description = "AKS control plane tier. Standard includes the uptime SLA (99.95% with availability zones). Free has no SLA."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be one of Free, Standard, or Premium."
  }
}

variable "enable_private_cluster" {
  description = <<-EOT
    If true, the API server is exposed only on a private IP (fully private).
    In that case, kubectl and the Terraform kubernetes provider can connect only from inside the VNet (or via VPN/Bastion).
    The lab default is false: API Server VNet Integration + authorized IP ranges.
  EOT
  type        = bool
  default     = false
}

variable "zones" {
  description = "Availability zones to spread the node pools across"
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "system_node_vm_size" {
  description = "System node pool VM size (at least 4 vCPUs recommended)"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "system_node_min_count" {
  description = "Minimum node count for the System node pool (one per availability zone across 3 zones = 3)"
  type        = number
  default     = 3
}

variable "system_node_max_count" {
  description = "Maximum node count for the System node pool"
  type        = number
  default     = 5
}

variable "user_node_vm_size" {
  description = "User node pool VM size"
  type        = string
  default     = "Standard_D4ds_v5"
}

variable "user_node_min_count" {
  description = "Minimum node count for the User node pool (one per availability zone across 3 zones = 3)"
  type        = number
  default     = 3
}

variable "user_node_max_count" {
  description = "Maximum node count for the User node pool"
  type        = number
  default     = 6
}

variable "enable_spot_pool" {
  description = "Whether to add a Spot VM node pool (equivalent to EC2 Spot; for batch/fault-tolerant workloads)"
  type        = bool
  default     = false
}

variable "enable_gateway_api" {
  description = "Enable the Managed Gateway API CRDs + the application routing Gateway API implementation (approuting-istio)"
  type        = bool
  default     = true
}

variable "enable_defender" {
  description = "Attach the Microsoft Defender for Containers profile to the cluster (the subscription-level plan is enabled in 08-governance)"
  type        = bool
  default     = false
}

variable "grant_current_user_admin" {
  description = <<-EOT
    If true, grants cluster admin permissions (Azure RBAC Cluster Admin) to the "currently signed-in principal"
    that runs terraform. This is the lab default. In team/CI environments, set it to false and specify Entra groups
    in admin_principal_ids (permissions stay stable even when the executing principal changes).
  EOT
  type        = bool
  default     = true

  validation {
    condition     = var.grant_current_user_admin || length(var.admin_principal_ids) > 0
    error_message = "When grant_current_user_admin = false, specify at least one admin group/user in admin_principal_ids. (Local accounts are disabled, so with no admin, nobody can access the cluster.)"
  }
}

variable "admin_principal_ids" {
  description = "Object IDs of additional Entra users/groups to grant cluster admin permissions (Azure RBAC Cluster Admin). In team environments, prefer groups over individuals."
  type        = set(string)
  default     = []
}

variable "maintenance_utc_offset" {
  description = "UTC offset used for the maintenance windows (planned maintenance)"
  type        = string
  default     = "+09:00"
}

variable "pod_cidr" {
  description = "Azure CNI Overlay pod CIDR. Must not overlap with the VNet or on-premises ranges. Use the same value as pod_cidr in 03-network (the node NSG allow rule)."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "kube-dns Service IP (an address within service_cidr)"
  type        = string
  default     = "10.0.0.10"
}
