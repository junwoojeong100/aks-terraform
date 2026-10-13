locals {
  # Grants cluster admin permissions to the currently signed-in principal (grant_current_user_admin)
  # plus any additional principals you specify.
  admin_principal_ids = toset(concat(
    var.grant_current_user_admin ? [data.azurerm_client_config.current.object_id] : [],
    tolist(var.admin_principal_ids),
  ))
}

# ---------------------------------------------------------------------------
# Human access to the cluster = Azure RBAC role assignments
#   - Cluster User Role      : permission to fetch a kubeconfig with `az aks get-credentials` (ARM permission)
#   - RBAC Cluster Admin     : permission equivalent to cluster-admin on the Kubernetes API (data plane permission)
# Azure RBAC alone covers what EKS does with its "IAM principal → access entry → access policy" flow.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "cluster_user" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
