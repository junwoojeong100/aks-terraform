# ---------------------------------------------------------------------------
# AKS Automatic  (the "we operate it for you" mode, equivalent to Amazon EKS Auto Mode)
#
# Most of the settings you configured by hand in 05-aks are "preconfigured" here, so the code is much shorter.
#   - Managed system node pool, Node Auto Provisioning (Karpenter-based) node autoscaling
#   - Azure CNI Overlay + Cilium, egress through a managed NAT Gateway
#   - Standard tier (uptime SLA) + Pod readiness SLA, auto upgrades (stable channel, N-1), automatic node image replacement
#   - Entra ID + Azure RBAC (no local accounts), Workload Identity/OIDC, Deployment Safeguards, image cleaner
#   - HPA / KEDA / VPA, node auto-repair, node resource group lockdown
#
# Note: Managed Prometheus / Container Insights are enabled by default only when you create the cluster with the
#       Azure CLI or the portal. This cluster, created with Terraform, is not connected to them, so connect them
#       yourself if you need them (as in 05-aks/monitoring.tf).
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_automatic_cluster" "this" {
  name                = module.naming.names.aks_automatic
  location            = azurerm_resource_group.automatic.location
  resource_group_name = azurerm_resource_group.automatic.name

  # managed VNet: SystemAssigned is enough. BYO VNet: needs a UserAssigned identity that was granted permissions beforehand.
  identity {
    type         = local.byo ? "UserAssigned" : "SystemAssigned"
    identity_ids = local.byo ? [azurerm_user_assigned_identity.aks[0].id] : null
  }

  api_server_access {
    authorized_ip_ranges = var.allowed_ip_ranges
    subnet_id            = local.byo ? azurerm_subnet.api_server[0].id : null
  }

  dynamic "hosted_system" {
    for_each = local.byo ? [1] : []

    content {
      node_subnet_id        = azurerm_subnet.user_nodes[0].id
      system_node_subnet_id = azurerm_subnet.system_nodes[0].id
    }
  }

  # Ingress: Gateway API implementation (approuting-istio) instead of NGINX.
  # Same as the default for new Automatic clusters on AKS 1.36+.
  web_app_routing_ingress {
    istio_enabled = true
  }

  tags = local.tags

  depends_on = [azurerm_role_assignment.network_contributor]
}

# Automatic uses only Azure RBAC, so people need role assignments too.
# Grant them to the currently signed-in principal (grant_current_user_admin) and to the principals listed in
# admin_principal_ids (an Entra group is recommended in team environments).
locals {
  admin_principal_ids = toset(concat(
    var.grant_current_user_admin ? [data.azurerm_client_config.current.object_id] : [],
    tolist(var.admin_principal_ids),
  ))
}

resource "azurerm_role_assignment" "cluster_user" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_automatic_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = local.admin_principal_ids

  scope                = azurerm_kubernetes_automatic_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}
