# ---------------------------------------------------------------------------
# Two managed identities used by AKS (cluster / kubelet)
#
# Mapping to AWS
#   - cluster identity  ≈ EKS cluster IAM role   (the control plane manages LBs, disks, subnets, etc.)
#   - kubelet identity  ≈ EKS node IAM role      (nodes pull images from ACR)
# Instead of "attaching a trust policy to a Role", Azure has you create a resource (UAMI) and
# add a role assignment at the scope of the target resource. There are no long-lived credentials (keys).
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "aks_cluster" {
  name                = module.naming.names.id_aks_cluster
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = module.naming.names.id_aks_kubelet
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

# Network Contributor on the network resource group so the control plane can use the subnets/NAT Gateway of the BYO VNet.
# (For stricter access, you can narrow the scope to the VNet / subnet.)
resource "azurerm_role_assignment" "cluster_network" {
  scope                = data.azurerm_resource_group.network.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# To use a BYO kubelet identity, the control plane identity must be able to attach the kubelet identity to the nodes.
resource "azurerm_role_assignment" "cluster_manages_kubelet" {
  scope                = azurerm_user_assigned_identity.aks_kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# Lets the nodes (kubelet) pull images from ACR: equivalent to the ECR permissions ecr:GetAuthorizationToken / BatchGetImage.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
  principal_type       = "ServicePrincipal"
}

# Grant AcrPush so the lab user (the currently signed-in user) can push images.
# In team/CI environments, turn this off with grant_current_user_roles = false and assign roles to
# a group/CI principal separately.
resource "azurerm_role_assignment" "operator_acr_push" {
  count = var.grant_current_user_roles ? 1 : 0

  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}
