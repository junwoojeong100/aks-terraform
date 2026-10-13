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

variable "policy_effect" {
  description = <<-EOT
    Effect of the pod security initiatives (baseline/restricted).
    Audit = only record violations (lab default), Deny = block creation of violating resources.
    Turn on Deny only after you have confirmed that the workloads you plan to deploy to the cluster satisfy the policy.
  EOT
  type        = string
  default     = "Audit"

  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.policy_effect)
    error_message = "policy_effect must be one of Audit, Deny, or Disabled."
  }
}

variable "enable_defender_plan" {
  description = <<-EOT
    Enable the subscription-level Microsoft Defender for Containers plan.
    It affects the whole subscription and is billed per vCore, so the default is false.
  EOT
  type        = bool
  default     = false
}

variable "enable_resource_locks" {
  description = "Set a CanNotDelete lock on the network/platform resource groups (you must remove it before cleaning up the lab)."
  type        = bool
  default     = false
}

variable "enable_budget" {
  description = "Create a monthly budget alert based on the workload tag (requires budget_alert_emails)"
  type        = bool
  default     = false
}

variable "budget_amount" {
  description = "Monthly budget amount (in the subscription's billing currency)"
  type        = number
  default     = 100
}

variable "budget_alert_emails" {
  description = "List of email addresses to receive budget alerts"
  type        = list(string)
  default     = []
}
