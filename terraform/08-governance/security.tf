# ---------------------------------------------------------------------------
# Microsoft Defender for Containers  (equivalent to GuardDuty EKS Protection + Inspector (ECR scanning) + Security Hub)
#   - Turning on the subscription-level "plan" works together with the cluster-level microsoft_defender profile
#     (05-aks: enable_defender + defender_log_analytics_workspace_id).
#   - Features: runtime threat detection, ACR image vulnerability scanning,
#     misconfiguration (Kubernetes security posture) assessment
# ---------------------------------------------------------------------------
resource "azurerm_security_center_subscription_pricing" "containers" {
  count = var.enable_defender_plan ? 1 : 0

  resource_type = "Containers"
  tier          = "Standard"
}

# ---------------------------------------------------------------------------
# Resource locks (similar to CloudFormation stack policies / Termination Protection)
# ---------------------------------------------------------------------------
resource "azurerm_management_lock" "network" {
  count = var.enable_resource_locks ? 1 : 0

  name       = "lock-do-not-delete"
  scope      = data.azurerm_resource_group.network.id
  lock_level = "CanNotDelete"
  notes      = "The network is shared by several stacks, so this lock prevents accidental deletion."
}

resource "azurerm_management_lock" "platform" {
  count = var.enable_resource_locks ? 1 : 0

  name       = "lock-do-not-delete"
  scope      = data.azurerm_resource_group.platform.id
  lock_level = "CanNotDelete"
  notes      = "Protects the shared ACR / Key Vault / monitoring services"
}
