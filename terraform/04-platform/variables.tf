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
    Administrator public IPs (list of CIDRs) to allow through the ACR / Key Vault firewalls.
    Example: export TF_VAR_allowed_ip_ranges='["203.0.113.10/32"]'
    Nodes/pods connect through Private Endpoints, so this list is for "people/CI".
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ip_ranges) > 0 && alltrue([for cidr in var.allowed_ip_ranges : can(cidrhost(cidr, 0))])
    error_message = "Specify at least one CIDR in allowed_ip_ranges. Example: export TF_VAR_allowed_ip_ranges='[\"203.0.113.10/32\"]'"
  }
}

variable "enable_grafana" {
  description = "Whether to create Azure Managed Grafana (the Standard SKU is billed hourly)."
  type        = bool
  default     = true
}

variable "grant_current_user_roles" {
  description = <<-EOT
    If true, grants lab roles (AcrPush on ACR, Grafana Admin on Grafana) to the "currently signed-in principal"
    that runs terraform. In team/CI environments, set it to false and assign roles to an Entra group (for people)
    or a separate service principal (for CI) instead.
  EOT
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Log Analytics retention period (days)"
  type        = number
  default     = 30
}

variable "log_daily_quota_gb" {
  description = "Log Analytics daily ingestion cap (GB). A safeguard against runaway lab costs. -1 means unlimited."
  type        = number
  default     = 5
}

variable "key_vault_purge_protection_enabled" {
  description = "Key Vault purge protection. true is recommended in production; once enabled, it cannot be disabled."
  type        = bool
  default     = true
}
