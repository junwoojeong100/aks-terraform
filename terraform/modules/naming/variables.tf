variable "workload" {
  description = "Workload name (3–8 lowercase letters or digits). Example: aksdemo"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.workload))
    error_message = "workload must be 3–8 lowercase letters or digits (due to Key Vault and Storage name length limits)."
  }
}

variable "environment" {
  description = "Environment (dev, test, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of dev, test, or prod."
  }
}

variable "location" {
  description = "Azure region name (e.g., koreacentral)"
  type        = string
}

variable "subscription_id" {
  description = "Subscription ID. Used to compute the hash suffix appended to globally unique names (ACR, Key Vault, Storage)."
  type        = string
}
