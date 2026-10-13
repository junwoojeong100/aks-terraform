# ---------------------------------------------------------------------------
# AKS 가 사용할 Managed Identity 두 개 (cluster / kubelet)
#
# AWS 와의 대응
#   - cluster identity  ≈ EKS cluster IAM role   (컨트롤 플레인이 LB, 디스크, 서브넷 등을 관리)
#   - kubelet identity  ≈ EKS node IAM role      (노드가 ACR 이미지를 pull)
# Azure 에서는 "Role 에 신뢰 정책을 붙이는" 대신, 리소스(UAMI)를 만들고
# 대상 리소스 scope 에 역할 할당(role assignment)을 추가합니다. 장기 자격 증명(키)은 없습니다.
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

# 컨트롤 플레인이 BYO VNet 의 서브넷/NAT Gateway 를 사용할 수 있도록 네트워크 리소스 그룹에 Network Contributor.
# (더 엄격하게 하려면 VNet / 서브넷 scope 로 좁힐 수 있습니다.)
resource "azurerm_role_assignment" "cluster_network" {
  scope                = data.azurerm_resource_group.network.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# BYO kubelet identity 를 쓰려면 컨트롤 플레인 identity 가 kubelet identity 를 노드에 붙일 수 있어야 합니다.
resource "azurerm_role_assignment" "cluster_manages_kubelet" {
  scope                = azurerm_user_assigned_identity.aks_kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.aks_cluster.principal_id
  principal_type       = "ServicePrincipal"
}

# 노드(kubelet)가 ACR 에서 이미지를 pull: ECR 의 ecr:GetAuthorizationToken / BatchGetImage 권한에 해당.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
  principal_type       = "ServicePrincipal"
}

# 실습자(현재 로그인 사용자)가 이미지를 push 할 수 있도록 AcrPush 부여.
# 팀/CI 환경에서는 grant_current_user_roles = false 로 끄고, 그룹/CI 주체에 별도로 역할을 부여하세요.
resource "azurerm_role_assignment" "operator_acr_push" {
  count = var.grant_current_user_roles ? 1 : 0

  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}
