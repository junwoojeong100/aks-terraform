# ---------------------------------------------------------------------------
# Azure Policy for AKS  (combines the roles of AWS Config rules + SCPs + Kyverno/Gatekeeper)
#
#   - Checks on cluster "configuration": ARM-level policies (e.g. block local accounts, authorized IP ranges)
#                                        → similar to AWS Config rules
#   - Checks "inside" the cluster      : the Azure Policy add-on (Gatekeeper) evaluates at Kubernetes admission
#                                        → similar to Kyverno/OPA
#
# The assignment scope is the resource group that contains the cluster. Assigning at the subscription or
# management group level makes every cluster inherit the policies.
# ---------------------------------------------------------------------------
locals {
  # System namespaces to exclude from policy evaluation (initiative defaults + AKS managed add-ons)
  policy_excluded_namespaces = [
    "kube-system",
    "gatekeeper-system",
    "azure-arc",
    "azure-extensions-usage-system",
    "aks-istio-system",
    "app-routing-system",
  ]

  # Built-in policy initiatives (policySet): Pod Security Standards (Linux)
  pod_security_initiatives = {
    baseline = {
      id           = "/providers/Microsoft.Authorization/policySetDefinitions/a8640138-9b0a-4a28-b8cb-1666c838647d"
      display_name = "AKS pod security baseline (Linux)"
    }
    restricted = {
      id           = "/providers/Microsoft.Authorization/policySetDefinitions/42b8ef37-b724-4e24-bbc8-7a7708edfe00"
      display_name = "AKS pod security restricted (Linux)"
    }
  }

  # Built-in policy definitions: cluster configuration checks (all Audit-only)
  cluster_config_policies = {
    local-auth-disabled = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/993c2fcd-2b29-49d2-9eb0-df2c3a730c32"
      display_name = "AKS clusters should have local authentication methods disabled"
    }
    policy-addon-enabled = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/0a15ec92-a229-4763-bb14-0ea34a568f8d"
      display_name = "The Azure Policy add-on should be installed on AKS clusters"
    }
    rbac-enabled = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/ac4a19c2-fa67-49b4-8ae5-0b2e78c49457"
      display_name = "Kubernetes RBAC should be used"
    }
    authorized-ip-ranges = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/0e246bcf-5f6f-4f87-bc6f-775d4712c7ea"
      display_name = "API server authorized IP ranges should be defined"
    }
    managed-identity = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/da6e2401-19da-4532-9141-fb8fbde08431"
      display_name = "AKS clusters should use a managed identity"
    }
    defender-profile = {
      id           = "/providers/Microsoft.Authorization/policyDefinitions/a1840de2-8088-4ea8-b153-b4c723e9cb01"
      display_name = "AKS clusters should have the Defender profile enabled"
    }
  }
}

resource "azurerm_resource_group_policy_assignment" "pod_security" {
  for_each = local.pod_security_initiatives

  name                 = "aks-pod-security-${each.key}"
  display_name         = each.value.display_name
  resource_group_id    = data.azurerm_resource_group.aks.id
  policy_definition_id = each.value.id

  # Only baseline follows var.policy_effect; restricted always stays Audit to show the "readiness for the next step".
  parameters = jsonencode({
    effect = {
      value = each.key == "baseline" ? var.policy_effect : "Audit"
    }
    excludedNamespaces = {
      value = local.policy_excluded_namespaces
    }
  })

  non_compliance_message {
    content = "This violates the pod security standards. Check non-root execution, privilege escalation, resource limits, etc."
  }
}

resource "azurerm_resource_group_policy_assignment" "cluster_config" {
  for_each = local.cluster_config_policies

  name                 = "aks-${each.key}"
  display_name         = each.value.display_name
  resource_group_id    = data.azurerm_resource_group.aks.id
  policy_definition_id = each.value.id
}
