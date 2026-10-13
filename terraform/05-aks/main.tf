data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

locals {
  tags = merge(
    {
      workload    = var.workload
      environment = var.environment
      managed_by  = "terraform"
      lab         = "aks-terraform-guide"
    },
    var.tags,
  )
}

# ---------------------------------------------------------------------------
# 앞선 스택(03-network, 04-platform)의 산출물을 이름 규칙으로 조회
# ---------------------------------------------------------------------------
data "azurerm_subnet" "aks_nodes" {
  name                 = module.naming.names.snet_aks_nodes
  virtual_network_name = module.naming.names.vnet
  resource_group_name  = module.naming.names.rg_network
}

data "azurerm_subnet" "aks_apiserver" {
  name                 = module.naming.names.snet_aks_apiserver
  virtual_network_name = module.naming.names.vnet
  resource_group_name  = module.naming.names.rg_network
}

data "azurerm_user_assigned_identity" "cluster" {
  name                = module.naming.names.id_aks_cluster
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_user_assigned_identity" "kubelet" {
  name                = module.naming.names.id_aks_kubelet
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_log_analytics_workspace" "this" {
  name                = module.naming.names.log_analytics
  resource_group_name = module.naming.names.rg_platform
}

data "azurerm_monitor_workspace" "this" {
  name                = module.naming.names.monitor_workspace
  resource_group_name = module.naming.names.rg_platform
}

# 리전에서 지원하는 GA Kubernetes 버전 목록 (az aks get-versions 와 같은 정보)
data "azurerm_kubernetes_service_versions" "current" {
  location        = var.location
  include_preview = false
}

# check 블록은 apply 를 막지 않는 "경고용 검증"입니다. 지원되지 않는 버전을 넣으면 plan 단계에서 알려줍니다.
check "kubernetes_version_is_supported" {
  assert {
    condition = anytrue([
      for v in data.azurerm_kubernetes_service_versions.current.versions :
      v == var.kubernetes_version || startswith(v, "${var.kubernetes_version}.")
    ])
    error_message = "kubernetes_version=${var.kubernetes_version} 은(는) ${var.location} 에서 GA 로 지원되지 않습니다. 지원 목록: ${join(", ", data.azurerm_kubernetes_service_versions.current.versions)}"
  }
}

# ---------------------------------------------------------------------------
# 클러스터 리소스 그룹 (노드 리소스 그룹 'rg-...-aks-nodes' 는 AKS 가 별도로 생성/관리)
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "aks" {
  name     = module.naming.names.rg_aks
  location = var.location
  tags     = local.tags
}
