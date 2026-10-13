# ---------------------------------------------------------------------------
# AKS Automatic  (Amazon EKS Auto Mode 에 해당하는 "운영까지 맡기는" 모드)
#
# 05-aks 에서 직접 설정한 항목 대부분이 "미리 구성(preconfigured)" 되어 있어 코드가 훨씬 짧습니다.
#   - 관리형 시스템 노드 풀, Node Auto Provisioning(Karpenter 기반) 노드 오토스케일
#   - Azure CNI Overlay + Cilium, 관리형 NAT Gateway 로 egress
#   - Standard 등급(업타임 SLA) + Pod readiness SLA, 자동 업그레이드(stable 채널, N-1), 노드 이미지 자동 교체
#   - Entra ID + Azure RBAC(로컬 계정 없음), Workload Identity/OIDC, 배포 안전장치(Deployment Safeguards), 이미지 클리너
#   - HPA / KEDA / VPA, 노드 자동 복구(auto-repair), 노드 리소스 그룹 잠금(lockdown)
#
# 주의: Managed Prometheus / Container Insights 는 Azure CLI·포털로 만들 때만 기본 활성화됩니다.
#       Terraform 으로 만든 이 클러스터에는 연결되어 있지 않으므로, 필요하면 05-aks/monitoring.tf 처럼 직접 연결해야 합니다.
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_automatic_cluster" "this" {
  name                = module.naming.names.aks_automatic
  location            = azurerm_resource_group.automatic.location
  resource_group_name = azurerm_resource_group.automatic.name

  # managed VNet: SystemAssigned 로 충분. BYO VNet: 미리 권한을 준 UserAssigned 필요.
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

  # Ingress: NGINX 대신 Gateway API 구현(approuting-istio). AKS 1.36+ 의 새 Automatic 클러스터 기본값과 같습니다.
  web_app_routing_ingress {
    istio_enabled = true
  }

  tags = local.tags

  depends_on = [azurerm_role_assignment.network_contributor]
}

# Automatic 은 Azure RBAC 만 사용하므로 사람에게도 역할 할당이 필요합니다.
# 현재 로그인 주체(grant_current_user_admin) + admin_principal_ids 로 지정한 주체(팀 환경에서는 Entra 그룹 권장)에게 부여합니다.
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
