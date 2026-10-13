locals {
  # 현재 로그인한 주체(grant_current_user_admin) + 추가로 지정한 주체에게 클러스터 관리자 권한을 부여합니다.
  admin_principal_ids = toset(concat(
    var.grant_current_user_admin ? [data.azurerm_client_config.current.object_id] : [],
    tolist(var.admin_principal_ids),
  ))
}

# ---------------------------------------------------------------------------
# 사람의 클러스터 접근 = Azure RBAC 역할 할당
#   - Cluster User Role      : `az aks get-credentials` 로 kubeconfig 를 받을 수 있는 권한 (ARM 권한)
#   - RBAC Cluster Admin     : 쿠버네티스 API 에 대한 cluster-admin 과 동등한 권한 (데이터 플레인 권한)
# EKS 의 "IAM principal → access entry → access policy" 흐름을 Azure RBAC 하나로 처리합니다.
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
